import Cocoa
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import CoreVideo
import CoreImage
import ApplicationServices
import Carbon

func globalHotKeyHandlerCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {

    guard let userData = userData else {
        return noErr
    }

    let delegate =
        Unmanaged<AppDelegate>
            .fromOpaque(userData)
            .takeUnretainedValue()

    DispatchQueue.main.async {
        var hotKeyID = EventHotKeyID()

        if let event = event {
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
        }

        if hotKeyID.id == 1 {
            delegate.toggleRecording()
        } else if hotKeyID.id == 3 {
            if delegate.getCameraExpandedState() {
                delegate.collapseCamera()
            }
        }
    }

    return noErr
}

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@available(macOS 12.3, *)
class AppDelegate: NSObject,
                   NSApplicationDelegate,
                   SCStreamOutput,
                   SCStreamDelegate,
                   AVCaptureVideoDataOutputSampleBufferDelegate,
                   AVCaptureAudioDataOutputSampleBufferDelegate {

    // MARK: - Menu Bar

    var statusItem: NSStatusItem!
    var menu: NSMenu!

    var recordMenuItem: NSMenuItem!

    var micSubmenuItem: NSMenuItem!
    var micMenu: NSMenu!

    var screenSubmenuItem: NSMenuItem!
    var screenMenu: NSMenu!

    // MARK: - Recording State

    var isRecording = false
    var isWriting = false
    var isSessionStarted = false
    var isFinalizingRecording = false
    var isStartingRecording = false

    var baseStartTime: CMTime?

    // MARK: - Floating Camera

    var floatCamWindow: NSWindow!

    var captureSession: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?
    var cameraVideoOutput: AVCaptureVideoDataOutput?

    var audioCaptureSession: AVCaptureSession?

    var latestCameraPixelBuffer: CVPixelBuffer?
    let cameraFrameLock = NSLock()

    

// MARK: - Camera Hover Expansion

var isCameraExpanded = false

var cameraHoverStartTime: Date?
var cameraHovering = false

let cameraHoverDuration: TimeInterval = 0.7
let cameraExpandAnimationDuration: TimeInterval = 0.5

var cameraAnimStartRect: CGRect = .zero
var cameraAnimTargetRect: CGRect = .zero
var cameraAnimStartTime: Date = Date()
var cameraNormalWindowFrame: NSRect?

let cameraAnimationLock = NSLock()



    // MARK: - Screen Capture

    var stream: SCStream?

    var selectedDisplay: SCDisplay?

    var displayBounds: CGRect = .zero

    // MARK: - Video Writer

    var videoWriter: AVAssetWriter?
    var videoWriterInput: AVAssetWriterInput?
    var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    var audioWriterInput: AVAssetWriterInput?

    // MARK: - Core Image

    let ciContext = CIContext(
        options: [
            .useSoftwareRenderer: false
        ]
    )

    // MARK: - Output Size

    let outputWidth: CGFloat = 1280
    let outputHeight: CGFloat = 720

    // MARK: - Zoom

    let focusZoomWidth: CGFloat = 800
    let focusZoomHeight: CGFloat = 450

    let zoomLock = NSLock()

    var currentSourceRect: CGRect = .zero
    var targetSourceRect: CGRect = .zero
    var zoomAnimStartRect: CGRect = .zero

    var zoomAnimStartTime: Date = Date()

    let zoomAnimDuration: Double = 0.65
    let zoomFollowDuration: Double = 0.25
    var activeZoomAnimDuration: Double = 0.65
    let zoomIdleDelay: TimeInterval = 1.0

    // Smooth mouse follow
    var mouseFollowZoomEnabled: Bool = false
    var lastMouseFollowUpdate: Date = Date()
    let mouseFollowUpdateInterval: TimeInterval = 0.033  // ~30fps for smooth follow

    var lastActionTime: Date = .distantPast
    var lastActivityTime: Date = .distantPast
    var zoomIdleTimer: Timer?

    // MARK: - Click Effect

    let clickEffectLock = NSLock()

    var lastClickPoint: CGPoint?
    var clickEffectStartTime: Date?

    let clickEffectDuration: Double = 0.6

    // MARK: - Event Monitors

    var mouseClickMonitor: Any?
    var keyEventMonitor: Any?
    var mouseMoveMonitor: Any?
    var globalHotKeyRef: EventHotKeyRef?
    var escapeHotKeyRef: EventHotKeyRef?
    var globalHotKeyHandler: EventHandlerRef?
    var cameraExpandButton: NSButton?

    // MARK: - Application Launch

    func applicationDidFinishLaunching(
    _ notification: Notification
) {

    requestPermissions()

    requestAccessibilityPermission()

    setupMenuBareside()

    setupFloatingCamera()

    setupGlobalRecordingShortcut()

    
}

func setupGlobalRecordingShortcut() {

    var eventType = EventTypeSpec(
        eventClass:
            OSType(kEventClassKeyboard),
        eventKind:
            UInt32(kEventHotKeyPressed)
    )

    let hotKeyID = EventHotKeyID(
        signature:
            OSType(0x53524352),
        id:
            1
    )

    InstallEventHandler(
        GetApplicationEventTarget(),
        globalHotKeyHandlerCallback,
        1,
        &eventType,
        Unmanaged.passUnretained(self).toOpaque(),
        &globalHotKeyHandler
    )

    RegisterEventHotKey(
        UInt32(kVK_ANSI_R),
        UInt32(cmdKey | shiftKey),
        hotKeyID,
        GetApplicationEventTarget(),
        0,
        &globalHotKeyRef
    )

    let escapeHotKeyID = EventHotKeyID(
        signature:
            OSType(0x53524352),
        id:
            3
    )

    RegisterEventHotKey(
        UInt32(kVK_Escape),
        0,
        escapeHotKeyID,
        GetApplicationEventTarget(),
        0,
        &escapeHotKeyRef
    )

    keyEventMonitor =
        NSEvent.addGlobalMonitorForEvents(
            matching:
                [.keyDown]
        ) { [weak self] event in

            guard let self = self else {
                return
            }

            guard self.isWriting else {
                return
            }

            self.lastActionTime = Date()
            self.lastActivityTime = Date()

            if event.keyCode == 53,
               self.getCameraExpandedState() {
                self.collapseCamera()
                return
            }

            self.updateTargetZoomToMouse()
        }
}

func requestAccessibilityPermission() {

    let options = [
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
    ] as CFDictionary

    if !AXIsProcessTrustedWithOptions(options) {
        print("Accessibility permission is required to track typing activity")
    }
}

func recordingBeep() {
    NSSound.beep()
}

    





    // MARK: - Permissions

    func requestPermissions() {

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }

        AVCaptureDevice.requestAccess(
            for: .video
        ) { granted in

            if !granted {
                print("Camera permission denied")
            }
        }

        AVCaptureDevice.requestAccess(
            for: .audio
        ) { granted in

            if !granted {
                print("Microphone permission denied")
            }
        }
    }

    // MARK: - Menu Bar

    func setupMenuBareside() {

        statusItem =
            NSStatusBar.system.statusItem(
                withLength:
                    NSStatusItem.variableLength
            )

        if let button = statusItem.button {

            button.image =
                NSImage(
                    systemSymbolName:
                        "video.circle.fill",
                    accessibilityDescription:
                        "SImple Recorder"
                )

            button.toolTip =
                "SImple Recorder"
        }

        menu = NSMenu()

        // Record

        recordMenuItem =
            NSMenuItem(
                title:
                    "Start SImple Recording",
                action:
                    #selector(
                        toggleRecording
                    ),
                keyEquivalent:
                    "R"
            )

            recordMenuItem.keyEquivalentModifierMask = [
    .command,
    .shift
]

        recordMenuItem.target = self

        menu.addItem(
            recordMenuItem
        )

        menu.addItem(
            NSMenuItem.separator()
        )

        // Screen

        screenSubmenuItem =
            NSMenuItem(
                title:
                    "Select Screen",
                action:
                    nil,
                keyEquivalent:
                    ""
            )

        screenMenu = NSMenu()

        screenSubmenuItem.submenu =
            screenMenu

        menu.addItem(
            screenSubmenuItem
        )

        populateScreens()

        menu.addItem(
            NSMenuItem.separator()
        )

        // Microphone

        micSubmenuItem =
            NSMenuItem(
                title:
                    "Select Microphone",
                action:
                    nil,
                keyEquivalent:
                    ""
            )

        micMenu = NSMenu()

        micSubmenuItem.submenu =
            micMenu

        populateMicrophones()

        menu.addItem(
            micSubmenuItem
        )

        menu.addItem(
            NSMenuItem.separator()
        )

        // Quit

        let quitItem =
            NSMenuItem(
                title:
                    "Quit SImple Recorder",
                action:
                    #selector(
                        NSApplication.terminate(_:)
                    ),
                keyEquivalent:
                    "Q"
            )

        menu.addItem(
            quitItem
        )

        statusItem.menu = menu
    }

    // MARK: - Screen Selection

    func populateScreens() {

        SCShareableContent.getExcludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) { [weak self] content, error in

            guard let self = self,
                  let content = content else {

                print(
                    "Failed to list displays: \(String(describing: error))"
                )

                return
            }

            DispatchQueue.main.async {

                self.screenMenu.removeAllItems()

                for (
                    index,
                    display
                ) in content.displays.enumerated() {

                    let title =
                        "Display \(index + 1) (\(display.width)x\(display.height))"

                    let item =
                        NSMenuItem(
                            title:
                                title,
                            action:
                                #selector(
                                    self.selectScreen(_:)
                                ),
                            keyEquivalent:
                                ""
                        )

                    item.target = self

                    item.representedObject =
                        display

                    let selected =
                        self.selectedDisplay?.displayID ==
                        display.displayID
                        ||
                        (
                            self.selectedDisplay == nil
                            &&
                            index == 0
                        )

                    item.state =
                        selected
                        ? .on
                        : .off

                    self.screenMenu.addItem(
                        item
                    )
                }

                if self.selectedDisplay == nil {

                    self.selectedDisplay =
                        content.displays.first
                }
            }
        }
    }

    @objc func selectScreen(
        _ sender: NSMenuItem
    ) {

        for item in screenMenu.items {

            item.state = .off
        }

        sender.state = .on

        selectedDisplay =
            sender.representedObject as? SCDisplay
    }

    // MARK: - Microphone Selection

    func populateMicrophones() {

        micMenu.removeAllItems()

        let discoverySession =
            AVCaptureDevice.DiscoverySession(
                deviceTypes: [
                    .builtInMicrophone,
                    .externalUnknown
                ],
                mediaType:
                    .audio,
                position:
                    .unspecified
            )

        for device in discoverySession.devices {

            let item =
                NSMenuItem(
                    title:
                        device.localizedName,
                    action:
                        #selector(
                            selectMicrophone(_:)
                        ),
                    keyEquivalent:
                        ""
                )

            item.target = self

            item.state =
                micMenu.items.isEmpty
                ? .on
                : .off

            micMenu.addItem(
                item
            )
        }
    }

    @objc func selectMicrophone(
        _ sender: NSMenuItem
    ) {

        for item in micMenu.items {

            item.state = .off
        }

        sender.state = .on
    }

    // MARK: - Floating Camera

    func setupFloatingCamera() {

        floatCamWindow =
            NSWindow(
                contentRect:
                    NSRect(
                        x: 50,
                        y: 50,
                        width: 140,
                        height: 140
                    ),
                styleMask: [
                    .borderless,
                    .resizable
                ],
                backing:
                    .buffered,
                defer:
                    false
            )

        floatCamWindow.isOpaque =
            false

        floatCamWindow.backgroundColor =
            .clear

        floatCamWindow.level =
            .floating

        floatCamWindow.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]

        floatCamWindow.alphaValue =
            0.0

        floatCamWindow.isMovableByWindowBackground =
            true

        floatCamWindow.hasShadow =
            true

        guard let contentView =
                floatCamWindow.contentView else {
            return
        }

        contentView.wantsLayer =
            true

        contentView.layer?.backgroundColor =
            NSColor.black
                .withAlphaComponent(0.2)
                .cgColor

        contentView.layer?.cornerRadius =
            70

        contentView.layer?.masksToBounds =
            true

        // UI border

        contentView.layer?.borderColor =
            NSColor.systemGreen.cgColor

        contentView.layer?.borderWidth =
            3

        // Camera capture session

        captureSession =
            AVCaptureSession()

        if captureSession?.canSetSessionPreset(
    .hd1280x720
) == true {

    captureSession?.sessionPreset =
        .hd1280x720

} else {

    captureSession?.sessionPreset =
        .medium
}

        if let cameraDevice =
            AVCaptureDevice.default(
                for: .video
            ),
           let videoInput =
            try? AVCaptureDeviceInput(
                device:
                    cameraDevice
            ) {

            if captureSession?.canAddInput(
                videoInput
            ) == true {

                captureSession?.addInput(
                    videoInput
                )
            }
        }

        // Camera frame output

        if let session =
            captureSession {

            let videoOutput =
                AVCaptureVideoDataOutput()

            videoOutput.alwaysDiscardsLateVideoFrames =
                true

            videoOutput.setSampleBufferDelegate(
                self,
                queue:
                    DispatchQueue(
                        label:
                            "com.simplerecorder.cameraqueue"
                    )
            )

            if session.canAddOutput(
                videoOutput
            ) {

                session.addOutput(
                    videoOutput
                )

                cameraVideoOutput =
                    videoOutput
            }
        }

        // Preview

        if let session =
            captureSession {

            previewLayer =
                AVCaptureVideoPreviewLayer(
                    session:
                        session
                )

            previewLayer?.frame =
                contentView.bounds

            previewLayer?.autoresizingMask = [
                .layerWidthSizable,
                .layerHeightSizable
            ]

            previewLayer?.videoGravity =
                .resizeAspectFill

            previewLayer?.cornerRadius =
                70

            if let layer =
                previewLayer {

                contentView.layer?.addSublayer(
                    layer
                )
            }

            let expandButton =
                NSButton(
                    frame:
                        NSRect(
                            x:
                                contentView.bounds.width - 44,
                            y:
                                10,
                            width:
                                34,
                            height:
                                34
                        )
                )

            expandButton.image =
                NSImage(
                    systemSymbolName:
                        "arrow.up.left.and.arrow.down.right",
                    accessibilityDescription:
                        "Expand camera"
                )

            expandButton.imagePosition =
                .imageOnly

            expandButton.bezelStyle =
                .regularSquare

            expandButton.isBordered =
                true

            expandButton.isTransparent =
                false

            expandButton.wantsLayer =
                true

            expandButton.layer?.backgroundColor =
                NSColor.black
                    .withAlphaComponent(0.75)
                    .cgColor

            expandButton.layer?.cornerRadius =
                17

            expandButton.layer?.borderColor =
                NSColor.white
                    .withAlphaComponent(0.85)
                    .cgColor

            expandButton.layer?.borderWidth =
                1

            expandButton.imageScaling =
                .scaleProportionallyDown

            expandButton.contentTintColor =
                .white

            expandButton.toolTip =
                "Expand camera"

            expandButton.target =
                self

            expandButton.action =
                #selector(
                    toggleCameraExpansion(_:)
                )

            expandButton.autoresizingMask = [
                .minXMargin,
                .maxYMargin
            ]

            contentView.addSubview(
                expandButton,
                positioned:
                    .above,
                relativeTo:
                    nil
            )

            cameraExpandButton =
                expandButton

            expandButton.isHidden =
                true

            DispatchQueue.global(
                qos:
                    .userInitiated
            ).async {

                session.startRunning()

                DispatchQueue.main.async {

                    NSAnimationContext.runAnimationGroup {
                        context in

                        context.duration =
                            0.45

                        self.floatCamWindow
                            .animator()
                            .alphaValue =
                            1.0
                    }
                }
            }
        }

        floatCamWindow.makeKeyAndOrderFront(
            nil
        )
    }

    @objc func toggleCameraExpansion(
        _ sender: Any?
    ) {

        if getCameraExpandedState() {
            collapseCamera()
        } else {
            expandCamera()
        }
    }

    // MARK: - Toggle Recording

    @objc func toggleRecording() {

        if isFinalizingRecording || isStartingRecording {
            return
        }

        if isRecording {

            stopRecording()

        } else {

            startRecording()
        }
    }

    // MARK: - Start Recording

    func startRecording() {

        guard !isStartingRecording,
              !isFinalizingRecording,
              !isRecording else {
            return
        }

        isStartingRecording = true

        SCShareableContent.getExcludingDesktopWindows(
            false,
            onScreenWindowsOnly:
                true
        ) { [weak self] content, error in

            guard let self = self,
                  let content = content else {

                                self?.isStartingRecording = false

                print(
                    "Failed to get shareable content: \(String(describing: error))"
                )

                return
            }

            let targetDisplayID =
                self.selectedDisplay?.displayID

            guard let display =
                content.displays.first(
                    where: {
                        $0.displayID ==
                        targetDisplayID
                    }
                )
                ??
                content.displays.first else {

                self.isStartingRecording = false

                print(
                    "No display available"
                )

                return
            }

            self.selectedDisplay =
                display

            self.displayBounds =
                CGRect(
                    x: 0,
                    y: 0,
                    width:
                        CGFloat(
                            display.width
                        ),
                    height:
                        CGFloat(
                            display.height
                        )
                )

            // Reset zoom

self.zoomLock.lock()

self.currentSourceRect =
    self.displayBounds

self.targetSourceRect =
    self.displayBounds

self.zoomAnimStartRect =
    self.displayBounds

self.zoomAnimStartTime =
    Date()

 self.lastActivityTime =
    Date()

self.zoomLock.unlock()

// Reset mouse follow
self.lastMouseFollowUpdate = Date()


// Reset click effect

self.clickEffectLock.lock()

self.lastClickPoint =
    nil

self.clickEffectStartTime =
    nil

self.clickEffectLock.unlock()


// Reset camera hover expansion

self.cameraAnimationLock.lock()

self.isCameraExpanded =
    false

self.cameraHovering =
    false

self.cameraHoverStartTime =
    nil

let normalCameraRect =
    self.computeNormalCameraRectInOutput()
    ?? .zero

self.cameraAnimStartRect =
    normalCameraRect

self.cameraAnimTargetRect =
    normalCameraRect

self.cameraAnimStartTime =
    Date()

self.cameraAnimationLock.unlock()

            // MARK: Mouse movement

            self.mouseMoveMonitor =
    NSEvent.addGlobalMonitorForEvents(
                matching: [
                    .mouseMoved,
                    .leftMouseDragged,
                    .rightMouseDragged,
                    .otherMouseDragged
                ]
    ) { [weak self] event in

        guard let self = self,
              self.isWriting else {
            return
        }

        self.lastActivityTime = Date()

        if self.isZoomedIn() {
            self.updateTargetZoomToMouse()
        }
    }

            // MARK: Mouse clicks

            self.mouseClickMonitor =
                NSEvent.addGlobalMonitorForEvents(
                    matching:
                        [
                            .leftMouseDown,
                            .rightMouseDown
                        ]
                ) { [weak self] event in

                    guard let self = self,
                          self.isWriting else {
                        return
                    }

                    if let cameraWindow = self.floatCamWindow,
                       cameraWindow.frame.contains(
                           NSEvent.mouseLocation
                       ) {
                        return
                    }

                    self.lastActionTime =
                        Date()

                    self.lastActivityTime =
                        Date()

                    // Capture click point

                    if let point =
                        self.convertGlobalPointToSelectedDisplayPixels(
                            NSEvent.mouseLocation
                        ) {

                        self.clickEffectLock.lock()

                        self.lastClickPoint =
                            point

                        self.clickEffectStartTime =
                            Date()

                        self.clickEffectLock.unlock()
                    }

                    self.updateTargetZoomToMouse()
                }

            // Exclude recorder app

            let excludedApps =
                content.applications.filter {
                    $0.bundleIdentifier ==
                    Bundle.main.bundleIdentifier
                }

            let filter =
                SCContentFilter(
                    display:
                        display,
                    excludingApplications:
                        excludedApps,
                    exceptingWindows:
                        []
                )

            let config =
                SCStreamConfiguration()

            config.width =
                display.width

            config.height =
                display.height

            config.minimumFrameInterval =
                CMTime(
                    value:
                        1,
                    timescale:
                        30
                )

            config.pixelFormat =
                kCVPixelFormatType_32BGRA

            config.showsCursor =
                true

            let queue =
                DispatchQueue(
                    label:
                        "com.simplerecorder.streamqueue",
                    qos:
                        .userInteractive
                )

            self.stream =
                SCStream(
                    filter:
                        filter,
                    configuration:
                        config,
                    delegate:
                        self
                )

            do {

                try self.stream?.addStreamOutput(
                    self,
                    type:
                        .screen,
                    sampleHandlerQueue:
                        queue
                )

            } catch {

                self.isStartingRecording = false

                print(
                    "Error adding stream output: \(error)"
                )

                return
            }

            // MARK: Output File

            guard let desktop =
                FileManager.default.urls(
                    for:
                        .desktopDirectory,
                    in:
                        .userDomainMask
                ).first else {

                self.isStartingRecording = false

                return
            }

            let outputPath =
                desktop.appendingPathComponent(
                    "StudioRecording-\(UUID().uuidString).mp4"
                )

            try? FileManager.default.removeItem(
                at:
                    outputPath
            )

            self.videoWriter =
                try? AVAssetWriter(
                    outputURL:
                        outputPath,
                    fileType:
                        .mp4
                )

            guard self.videoWriter != nil else {

                self.isStartingRecording = false

                print(
                    "Could not create video writer"
                )

                return
            }

            // MARK: Video

            let videoSettings: [String: Any] = [

    AVVideoCodecKey:
        AVVideoCodecType.h264,

    AVVideoWidthKey:
    Int(self.outputWidth),

AVVideoHeightKey:
    Int(self.outputHeight),

    AVVideoCompressionPropertiesKey: [

        AVVideoAverageBitRateKey:
            8_000_000,

        AVVideoProfileLevelKey:
            AVVideoProfileLevelH264HighAutoLevel
    ]
]

            self.videoWriterInput =
                AVAssetWriterInput(
                    mediaType:
                        .video,
                    outputSettings:
                        videoSettings
                )

            self.videoWriterInput?
                .expectsMediaDataInRealTime =
                true

            let sourcePixelBufferAttributes:
                [String: Any] = [

                    kCVPixelBufferPixelFormatTypeKey
                        as String:
                        Int(
                            kCVPixelFormatType_32BGRA
                        ),

                    kCVPixelBufferWidthKey
                        as String:
                        Int(
                            self.outputWidth
                        ),

                    kCVPixelBufferHeightKey
                        as String:
                        Int(
                            self.outputHeight
                        )
                ]

            self.pixelBufferAdaptor =
                AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput:
                        self.videoWriterInput!,
                    sourcePixelBufferAttributes:
                        sourcePixelBufferAttributes
                )

            if let writer =
                self.videoWriter,
               let input =
                self.videoWriterInput,
               writer.canAdd(
                    input
               ) {

                writer.add(
                    input
                )
            }

            // MARK: Audio

            let audioSettings:
                [String: Any] = [

                    AVFormatIDKey:
                        kAudioFormatMPEG4AAC,

                    AVNumberOfChannelsKey:
                        2,

                    AVSampleRateKey:
                        44100.0,

                    AVEncoderBitRateKey:
                        128000
                ]

            self.audioWriterInput =
                AVAssetWriterInput(
                    mediaType:
                        .audio,
                    outputSettings:
                        audioSettings
                )

            self.audioWriterInput?
                .expectsMediaDataInRealTime =
                true

            if let writer =
                self.videoWriter,
               let audioInput =
                self.audioWriterInput,
               writer.canAdd(
                    audioInput
               ) {

                writer.add(
                    audioInput
                )
            }

            self.isSessionStarted =
                false

            self.baseStartTime =
                nil

            guard self.videoWriter?.startWriting() == true,
                  self.videoWriter?.status == .writing else {

                self.isStartingRecording = false

                print(
                    "Could not start video writer: \(String(describing: self.videoWriter?.error))"
                )

                return
            }

            self.isWriting =
                true

            self.isRecording =
                true

            DispatchQueue.main.async {
                self.cameraExpandButton?.isHidden = false
            }

            self.isStartingRecording =
                false

            self.isFinalizingRecording =
                false

            DispatchQueue.main.async {
                self.zoomIdleTimer?.invalidate()
                self.zoomIdleTimer = Timer.scheduledTimer(
                    withTimeInterval: 0.1,
                    repeats: true
                ) { [weak self] _ in
                    guard let self = self,
                          self.isWriting,
                          self.isZoomedIn(),
                          Date().timeIntervalSince(self.lastActivityTime) > self.zoomIdleDelay else {
                        return
                    }

                    self.setZoomTarget(self.displayBounds)
                }
            }

                DispatchQueue.main.async {
    self.recordingBeep()
}

            self.setupAudioCapture()



            self.stream?.startCapture {
                [weak self] error in

                if let error =
                    error {

                    print(
                        "Error starting capture: \(error)"
                    )

                    DispatchQueue.main.async {
                        self?.stopRecording()
                    }
                }
            }

            DispatchQueue.main.async {

                self.recordMenuItem.title =
                    "Stop Studio Recording"

                if let button =
                    self.statusItem.button {

                    button.image =
                        NSImage(
                            systemSymbolName:
                                "stop.circle.fill",
                            accessibilityDescription:
                                "Recording Active"
                        )

                    button.contentTintColor =
                        .red
                }
            }


        }
    }

    // MARK: - Global Point Conversion

    func convertGlobalPointToSelectedDisplayPixels(
        _ globalPoint: CGPoint
    ) -> CGPoint? {

        guard let display =
            selectedDisplay else {

            return nil
        }

        let matchingScreen =
            NSScreen.screens.first {
                screen in

                guard let screenNumber =
                    screen.deviceDescription[
                        NSDeviceDescriptionKey(
                            "NSScreenNumber"
                        )
                    ] as? NSNumber else {

                    return false
                }

                return
                    CGDirectDisplayID(
                        screenNumber.uint32Value
                    )
                    ==
                    display.displayID
            }

        guard let screen =
            matchingScreen else {

            return nil
        }

        let screenFrame =
            screen.frame

        guard screenFrame.contains(
            globalPoint
        ) else {

            return nil
        }

        let scale =
            screen.backingScaleFactor

        let relX =
            globalPoint.x -
            screenFrame.origin.x

        let relYBottom =
            globalPoint.y -
            screenFrame.origin.y

        let relYTop =
            screenFrame.height -
            relYBottom

        return CGPoint(
            x:
                relX * scale,
            y:
                relYTop * scale
        )
    }

    // MARK: - Update Zoom

    func isZoomedIn() -> Bool {

        zoomLock.lock()

        let zoomedIn =
            targetSourceRect != displayBounds

        zoomLock.unlock()

        return zoomedIn
    }

    func updateTargetZoomToMouse() {

        let now = Date()
        let elapsed = now.timeIntervalSince(
            lastMouseFollowUpdate
        )
        
        // Only update zoom position at ~30fps for smoothness
        guard elapsed >= mouseFollowUpdateInterval else {
            return
        }
        
        lastMouseFollowUpdate = now

        guard let displayPoint =
            convertGlobalPointToSelectedDisplayPixels(
                NSEvent.mouseLocation
            ) else {
            return
        }

        let maxX =
            max(
                0,
                displayBounds.width -
                    focusZoomWidth
            )

        let maxY =
            max(
                0,
                displayBounds.height -
                    focusZoomHeight
            )

        let tx =
            max(
                0,
                min(
                    displayPoint.x -
                        focusZoomWidth / 2,
                    maxX
                )
            )

        let ty =
            max(
                0,
                min(
                    displayPoint.y -
                        focusZoomHeight / 2,
                    maxY
                )
            )

        let newTarget = CGRect(
            x: tx,
            y: ty,
            width: focusZoomWidth,
            height: focusZoomHeight
        )

        // Only trigger new animation if position changed significantly
        zoomLock.lock()
        let current = currentSourceRect
        zoomLock.unlock()

        let _ = abs(newTarget.origin.x - current.origin.x)
        let _ = abs(newTarget.origin.y - current.origin.y)

        // Update more frequently with shorter duration for smooth mouse follow
        setZoomTarget(
            newTarget,
            animationDuration: 0.12
        )
    }

    // MARK: - Set Zoom Target

    func setZoomTarget(
        _ newTarget: CGRect,
        animationDuration: Double? = nil
    ) {

        zoomLock.lock()

        if newTarget !=
            targetSourceRect {

            zoomAnimStartRect =
                currentSourceRect

            targetSourceRect =
                newTarget

            activeZoomAnimDuration =
                animationDuration ?? zoomAnimDuration

            zoomAnimStartTime =
                Date()
        }

        zoomLock.unlock()
    }

    // MARK: - Camera Hover Detection

func updateCameraHover(
    mouseLocation: CGPoint
) {

    guard isWriting,
          floatCamWindow != nil else {
        return
    }

    let cameraFrame =
        floatCamWindow.frame

    let inside =
        cameraFrame.contains(
            mouseLocation
        )

    if inside {

        if !cameraHovering {

            cameraHovering = true

            cameraHoverStartTime =
                Date()
        }

    } else {

        if cameraHovering {

            cameraHovering = false

            cameraHoverStartTime =
                nil

            collapseCamera()
        }
    }
}

// MARK: - Process Camera Hover

func processCameraHover() {

    guard isWriting else {
        return
    }

    cameraAnimationLock.lock()

    let hovering =
        cameraHovering

    let hoverStart =
        cameraHoverStartTime

    let expanded =
        isCameraExpanded

    cameraAnimationLock.unlock()

    guard hovering,
          let hoverStart =
            hoverStart else {
        return
    }

    let elapsed =
        Date().timeIntervalSince(
            hoverStart
        )

    if elapsed >= cameraHoverDuration &&
       !expanded {

        expandCamera()
    }
}

    // MARK: - Camera Hover



func expandCamera() {

    guard Thread.isMainThread else {
        DispatchQueue.main.async { [weak self] in
            self?.expandCamera()
        }
        return
    }

    guard let cameraWindow = floatCamWindow else {
        return
    }

    let normalWindowFrame =
        cameraWindow.frame

    let currentRect =
        computeNormalCameraRectInOutput(
            windowFrame:
                normalWindowFrame
        )
        ?? cameraAnimTargetRect

    let screenFrame =
        NSScreen.screens.first {
            screen in

            guard let number =
                screen.deviceDescription[
                    NSDeviceDescriptionKey(
                        "NSScreenNumber"
                    )
                ] as? NSNumber else {
                return false
            }

            return CGDirectDisplayID(
                number.uint32Value
            ) == selectedDisplay?.displayID
        }?.frame
        ?? cameraWindow.frame

    cameraAnimationLock.lock()

    guard !isCameraExpanded else {
        cameraAnimationLock.unlock()
        return
    }

    cameraAnimStartRect =
        currentRect

    cameraAnimTargetRect =
        CGRect(
            x: 0,
            y: 0,
            width: outputWidth,
            height: outputHeight
        )

    cameraAnimStartTime =
        Date()

    cameraNormalWindowFrame =
        normalWindowFrame

    isCameraExpanded =
        true

    cameraAnimationLock.unlock()

    cameraWindow.contentView?.layer?.cornerRadius = 0
    previewLayer?.cornerRadius = 0

    NSAnimationContext.runAnimationGroup {
        context in

        context.duration =
            cameraExpandAnimationDuration

        cameraWindow.animator().setFrame(
            screenFrame,
            display:
                true
        )
    }
}

func collapseCamera() {

    guard Thread.isMainThread else {
        DispatchQueue.main.async { [weak self] in
            self?.collapseCamera()
        }
        return
    }

    guard let cameraWindow = floatCamWindow else {
        return
    }

    cameraAnimationLock.lock()

    guard isCameraExpanded else {
        cameraAnimationLock.unlock()
        return
    }

    let currentRect =
        cameraAnimTargetRect

    let normalWindowFrame =
        cameraNormalWindowFrame
        ?? cameraWindow.frame

    let normalRect =
        computeNormalCameraRectInOutput(
            windowFrame:
                normalWindowFrame
        )
        ?? .zero

    cameraAnimStartRect =
        currentRect

    cameraAnimTargetRect =
        normalRect

    cameraAnimStartTime =
        Date()

    isCameraExpanded =
        false

    cameraAnimationLock.unlock()

    cameraWindow.contentView?.layer?.cornerRadius =
        70
    previewLayer?.cornerRadius =
        70

    NSAnimationContext.runAnimationGroup {
        context in

        context.duration =
            cameraExpandAnimationDuration

        cameraWindow.animator().setFrame(
            normalWindowFrame,
            display:
                true
        )
    }
}

func getCameraExpandedState() -> Bool {

    cameraAnimationLock.lock()
    let expanded = isCameraExpanded
    cameraAnimationLock.unlock()

    return expanded
}

    // MARK: - Easing

    func easeInOutCubic(
        _ value: CGFloat
    ) -> CGFloat {

        let t =
            max(
                0,
                min(
                    value,
                    1
                )
            )

        if t < 0.5 {

            return
                4 *
                t *
                t *
                t

        } else {

            let f =
                2 * t - 2

            return
                0.5 *
                f *
                f *
                f +
                1
        }
    }

    func easeOutCubic(
        _ value: CGFloat
    ) -> CGFloat {

        let t =
            max(
                0,
                min(
                    value,
                    1
                )
            )

        let inverse =
            1 - t

        return
            1 -
            inverse *
            inverse *
            inverse
    }

    func easeInOutQuart(
        _ value: CGFloat
    ) -> CGFloat {

        let t =
            max(
                0,
                min(
                    value,
                    1
                )
            )

        if t < 0.5 {

            return
                8 *
                t *
                t *
                t *
                t

        } else {

            let f =
                t - 1

            return
                1 -
                8 *
                f *
                f *
                f *
                f
        }
    }

    // MARK: - Audio Capture

    func setupAudioCapture() {

        audioCaptureSession =
            AVCaptureSession()

        guard let session =
            audioCaptureSession else {
            return
        }

        let discoverySession =
            AVCaptureDevice.DiscoverySession(
                deviceTypes: [
                    .builtInMicrophone,
                    .externalUnknown
                ],
                mediaType:
                    .audio,
                position:
                    .unspecified
            )

        var selectedTitle =
            ""

        for item in micMenu.items {

            if item.state == .on {

                selectedTitle =
                    item.title

                break
            }
        }

        let targetDevice =
            discoverySession.devices.first {
                device in

                device.localizedName ==
                selectedTitle
            }
            ??
            AVCaptureDevice.default(
                for:
                    .audio
            )

        guard let device =
                targetDevice,
              let input =
                try? AVCaptureDeviceInput(
                    device:
                        device
                ) else {

            return
        }

        if session.canAddInput(
            input
        ) {

            session.addInput(
                input
            )
        }

        let audioOutput =
            AVCaptureAudioDataOutput()

        audioOutput.setSampleBufferDelegate(
            self,
            queue:
                DispatchQueue(
                    label:
                        "com.simplerecorder.audioqueue"
                )
        )

        if session.canAddOutput(
            audioOutput
        ) {

            session.addOutput(
                audioOutput
            )
        }

        DispatchQueue.global(
            qos:
                .userInitiated
        ).async {

            session.startRunning()
        }
    }

    // MARK: - Stop Recording

    func stopRecording() {

        guard !isFinalizingRecording else {
            return
        }

        isFinalizingRecording = true

        zoomIdleTimer?.invalidate()
        zoomIdleTimer = nil

        if getCameraExpandedState() {
            collapseCamera()
        }

    cameraAnimationLock.lock()

isCameraExpanded = false
cameraHovering = false
cameraHoverStartTime = nil

cameraAnimationLock.unlock()

        if let monitor =
            mouseClickMonitor {

            NSEvent.removeMonitor(
                monitor
            )

            mouseClickMonitor =
                nil
        }

        if let monitor =
            mouseMoveMonitor {

            NSEvent.removeMonitor(
                monitor
            )

            mouseMoveMonitor =
                nil
        }

        isRecording =
            false

        isWriting =
            false

        cameraExpandButton?.isHidden =
            true

        audioCaptureSession?
            .stopRunning()

        audioCaptureSession =
            nil

        if let activeStream = stream {
            activeStream.stopCapture {
                [weak self] error in

                if let error = error {
                    print(
                        "Error stopping capture: \(error)"
                    )
                }

                self?.finishRecordingWriter()
            }
        } else {
            finishRecordingWriter()
        }
    }

    func finishRecordingWriter() {

        DispatchQueue.global(
            qos:
                .userInitiated
        ).async { [weak self] in

            guard let self = self else {
                return
            }

            self.videoWriterInput?.markAsFinished()
            self.audioWriterInput?.markAsFinished()

            self.videoWriter?.finishWriting {
                DispatchQueue.main.async {

                    let writerStatus = self.videoWriter?.status
                    let writerError = self.videoWriter?.error

                    self.videoWriter = nil
                    self.videoWriterInput = nil
                    self.audioWriterInput = nil
                    self.pixelBufferAdaptor = nil
                    self.stream = nil
                    self.isSessionStarted = false
                    self.baseStartTime = nil
                    self.isFinalizingRecording = false

                    self.recordMenuItem.title =
                        "Start SImple Recording"

                    if let button = self.statusItem.button {
                        button.image = NSImage(
                            systemSymbolName:
                                "video.circle.fill",
                            accessibilityDescription:
                                "SImple Recorder"
                        )
                        button.contentTintColor = nil
                    }

                    if writerStatus == .completed {
                        print("Recording saved successfully!")
                    } else {
                        print(
                            "Recording failed: \(String(describing: writerError))"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Screen Capture Output

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {

        guard isWriting,
              let writer =
                videoWriter,
              type == .screen else {

            return
        }

        // Start writer session

        if !isSessionStarted {

            let pts =
                sampleBuffer.presentationTimeStamp

            baseStartTime =
                pts

            writer.startSession(
                atSourceTime:
                    pts
            )

            isSessionStarted =
                true
        }

        guard writer.status == .writing,
              let input =
                videoWriterInput,
              input.isReadyForMoreMediaData,
              pixelBufferAdaptor != nil,
              let imageBuffer =
                sampleBuffer.imageBuffer else {

            return
        }

        // Get zoom state

        zoomLock.lock()

        let startRect =
            zoomAnimStartRect

        let targetRect =
            targetSourceRect

        let animationStart =
            zoomAnimStartTime

        zoomLock.unlock()

        let elapsed =
            Date().timeIntervalSince(
                animationStart
            )

        let progress =
            activeZoomAnimDuration > 0
            ? CGFloat(
                elapsed /
                activeZoomAnimDuration
            )
            : 1

        let eased =
            easeInOutQuart(
                progress
            )

        var newRect =
            CGRect(
                x:
                    startRect.origin.x +
                    (
                        targetRect.origin.x -
                        startRect.origin.x
                    ) * eased,

                y:
                    startRect.origin.y +
                    (
                        targetRect.origin.y -
                        startRect.origin.y
                    ) * eased,

                width:
                    startRect.size.width +
                    (
                        targetRect.size.width -
                        startRect.size.width
                    ) * eased,

                height:
                    startRect.size.height +
                    (
                        targetRect.size.height -
                        startRect.size.height
                    ) * eased
            )

        // Clamp

        newRect.size.width =
            min(
                newRect.size.width,
                displayBounds.width
            )

        newRect.size.height =
            min(
                newRect.size.height,
                displayBounds.height
            )

        newRect.origin.x =
            max(
                0,
                min(
                    newRect.origin.x,
                    displayBounds.width -
                        newRect.size.width
                )
            )

        newRect.origin.y =
            max(
                0,
                min(
                    newRect.origin.y,
                    displayBounds.height -
                        newRect.size.height
                )
            )

        zoomLock.lock()

        currentSourceRect =
            newRect

        zoomLock.unlock()

        // Crop and render

        let cameraWindowFrame =
            currentCameraWindowFrame()

        if let croppedBuffer =
            cropAndResizePixelBuffer(
                imageBuffer,
                sourceRect:
                    newRect,
                cameraWindowFrame:
                    cameraWindowFrame
            ) {

            pixelBufferAdaptor?.append(
                croppedBuffer,
                withPresentationTime:
                    sampleBuffer.presentationTimeStamp
            )
        }
    }

    // MARK: - Crop and Resize

    func cropAndResizePixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        sourceRect: CGRect,
        cameraWindowFrame: CGRect?
    ) -> CVPixelBuffer? {

        let bufferHeight =
            CGFloat(
                CVPixelBufferGetHeight(
                    pixelBuffer
                )
            )

        let sourceImage =
            CIImage(
                cvPixelBuffer:
                    pixelBuffer
            )

        // ScreenCaptureKit:
        // top-left coordinate
        //
        // Core Image:
        // bottom-left coordinate

        let flippedY =
            bufferHeight -
            sourceRect.origin.y -
            sourceRect.height

        let cropRect =
            CGRect(
                x:
                    sourceRect.origin.x,
                y:
                    flippedY,
                width:
                    sourceRect.width,
                height:
                    sourceRect.height
            )

        guard cropRect.width > 0,
              cropRect.height > 0 else {

            return nil
        }

        let cropped =
            sourceImage.cropped(
                to:
                    cropRect
            )

        let originAdjusted =
            cropped.transformed(
                by:
                    CGAffineTransform(
                        translationX:
                            -cropRect.origin.x,
                        y:
                            -cropRect.origin.y
                    )
            )

        let scaleX =
            outputWidth /
            cropRect.width

        let scaleY =
            outputHeight /
            cropRect.height

        let scaled =
            originAdjusted.transformed(
                by:
                    CGAffineTransform(
                        scaleX:
                            scaleX,
                        y:
                            scaleY
                    )
            )

        // Camera first

        let cameraComposited =
            compositeCameraOverlay(
                on:
                    scaled,
                cameraWindowFrame:
                    cameraWindowFrame
            )

        // Click effect last

        let finalImage =
            compositeClickEffect(
                on:
                    cameraComposited
            )

        guard let pool =
            pixelBufferAdaptor?
                .pixelBufferPool else {

            return nil
        }

        var targetBuffer:
            CVPixelBuffer?

        let result =
            CVPixelBufferPoolCreatePixelBuffer(
                nil,
                pool,
                &targetBuffer
            )

        guard result ==
                kCVReturnSuccess,
              let outputBuffer =
                targetBuffer else {

            return nil
        }

        ciContext.render(
            finalImage,
            to:
                outputBuffer
        )

        return outputBuffer
    }

    // MARK: - Click Ripple

    func compositeClickEffect(
        on image: CIImage
    ) -> CIImage {

        clickEffectLock.lock()

        let clickPoint =
            lastClickPoint

        let startTime =
            clickEffectStartTime

        clickEffectLock.unlock()

        guard let clickPoint =
                clickPoint,
              let startTime =
                startTime else {

            return image
        }

        let elapsed =
            Date().timeIntervalSince(
                startTime
            )

        guard elapsed >= 0,
              elapsed <=
                clickEffectDuration else {

            return image
        }

        let progress =
            CGFloat(
                elapsed /
                clickEffectDuration
            )

        let eased =
            easeInOutQuart(
                progress
            )

        // Ripple

        let startRadius:
            CGFloat = 8

        let endRadius:
            CGFloat = 60

        let radius =
            startRadius +
            (
                endRadius -
                startRadius
            ) * eased

        // Fade

        let alpha =
            1 -
            eased

        // Get current zoom state for accurate click positioning
        zoomLock.lock()
        let currentZoomRect = currentSourceRect
        zoomLock.unlock()

        // Calculate click position relative to current zoom area
        // This ensures the red indicator appears exactly where clicked
        // even when zoom is active

        // Convert click point from display coordinates to zoom-relative coordinates
        let zoomX = clickPoint.x - currentZoomRect.origin.x
        let zoomY = clickPoint.y - currentZoomRect.origin.y

        // Scale to output dimensions
        let scaleX = outputWidth / currentZoomRect.width
        let scaleY = outputHeight / currentZoomRect.height

        let outputX = zoomX * scaleX
        let outputY = zoomY * scaleY

        // Radius scales with zoom level
        let radiusScale = scaleX

        let outputRadius =
            radius *
            radiusScale

        // CI coordinates are bottom-left.

        let center =
            CGPoint(
                x:
                    outputX,
                y:
                    outputHeight -
                    outputY
            )

        guard let filter =
                CIFilter(
                    name:
                        "CIRadialGradient"
                ) else {

            return image
        }

        filter.setValue(
            CIVector(
                x:
                    center.x,
                y:
                    center.y
            ),
            forKey:
                "inputCenter"
        )

        // Thin ring

        filter.setValue(
            max(
                outputRadius - 3,
                0
            ),
            forKey:
                "inputRadius0"
        )

        filter.setValue(
            outputRadius,
            forKey:
                "inputRadius1"
        )

        filter.setValue(
            CIColor(
                red:
                    1,
                green:
                    0,
                blue:
                    0,
                alpha:
                    alpha
            ),
            forKey:
                "inputColor0"
        )

        filter.setValue(
            CIColor(
                red:
                    1,
                green:
                    0,
                blue:
                    0,
                alpha:
                    0
            ),
            forKey:
                "inputColor1"
        )

        guard let ripple =
            filter.outputImage else {

            return image
        }

        return ripple.composited(
            over:
                image
        )
    }

    func currentCameraWindowFrame()
    -> CGRect? {

        guard floatCamWindow != nil else {
            return nil
        }

        if Thread.isMainThread {
            return floatCamWindow.frame
        }

        return DispatchQueue.main.sync {
            floatCamWindow.frame
        }
    }

    func computeNormalCameraRectInOutput(
        windowFrame: CGRect? = nil
    )
    -> CGRect? {

    guard let display =
            selectedDisplay,
          displayBounds.width > 0,
          displayBounds.height > 0 else {

        return nil
    }

    let matchingScreen =
        NSScreen.screens.first {
            screen in

            guard let number =
                screen.deviceDescription[
                    NSDeviceDescriptionKey(
                        "NSScreenNumber"
                    )
                ] as? NSNumber else {

                return false
            }

            return
                CGDirectDisplayID(
                    number.uint32Value
                )
                ==
                display.displayID
        }

    guard let screen =
            matchingScreen else {

        return nil
    }

    let scale =
        screen.backingScaleFactor

    let screenFrame =
        screen.frame

    let windowFrame =
        windowFrame ?? floatCamWindow.frame

    let relativeX =
        windowFrame.origin.x -
        screenFrame.origin.x

    let relativeYBottom =
        windowFrame.origin.y -
        screenFrame.origin.y

    let relativeYTop =
        screenFrame.height -
        relativeYBottom -
        windowFrame.height

    let pixelX =
        relativeX * scale

    let pixelY =
        relativeYTop * scale

    let pixelWidth =
        windowFrame.width * scale

    let pixelHeight =
        windowFrame.height * scale

    let normalizedX =
        pixelX /
        displayBounds.width

    let normalizedY =
        pixelY /
        displayBounds.height

    let normalizedWidth =
        pixelWidth /
        displayBounds.width

    let normalizedHeight =
        pixelHeight /
        displayBounds.height

    let outputX =
        normalizedX *
        outputWidth

    let outputY =
        normalizedY *
        outputHeight

    let outputWidthValue =
        normalizedWidth *
        outputWidth

    let outputHeightValue =
        normalizedHeight *
        outputHeight

    let diameter =
        min(
            outputWidthValue,
            outputHeightValue
        )

    return CGRect(
        x: outputX,
        y: outputY,
        width: diameter,
        height: diameter
    )
}

    // MARK: - Camera Position

    func computeCameraOverlayRectInOutput(
        cameraWindowFrame: CGRect?
    )
    -> CGRect? {

    guard let normalRect =
            computeNormalCameraRectInOutput(
                windowFrame:
                    cameraWindowFrame
            )
    else {
        return nil
    }

    // Not currently animating
    if cameraAnimStartRect == .zero ||
       cameraAnimTargetRect == .zero {

        return normalRect
    }

    cameraAnimationLock.lock()

    let startRect =
        cameraAnimStartRect

    let targetRect =
        cameraAnimTargetRect

    let startTime =
        cameraAnimStartTime

    let expanded =
        isCameraExpanded

    cameraAnimationLock.unlock()

    let elapsed =
        Date().timeIntervalSince(
            startTime
        )

    if elapsed >=
            cameraExpandAnimationDuration {

        return expanded
            ? targetRect
            : normalRect
    }

    let progress =
        CGFloat(
            min(
                max(
                    elapsed /
                    cameraExpandAnimationDuration,
                    0
                ),
                1
            )
        )

    let eased =
        easeInOutQuart(
            progress
        )

    return CGRect(
        x:
            startRect.origin.x +
            (
                targetRect.origin.x -
                startRect.origin.x
            ) * eased,

        y:
            startRect.origin.y +
            (
                targetRect.origin.y -
                startRect.origin.y
            ) * eased,

        width:
            startRect.width +
            (
                targetRect.width -
                startRect.width
            ) * eased,

        height:
            startRect.height +
            (
                targetRect.height -
                startRect.height
            ) * eased
    )
}

    // MARK: - Camera Composite

    func compositeCameraOverlay(
        on baseImage: CIImage,
        cameraWindowFrame: CGRect?
    ) -> CIImage {

        guard let overlayRect =
                computeCameraOverlayRectInOutput(
                    cameraWindowFrame:
                        cameraWindowFrame
                ),
              overlayRect.width > 10,
              overlayRect.height > 10 else {

            return baseImage
        }

        // Use the position calculated from this frame's window snapshot.

        let animatedRect =
            overlayRect

        cameraFrameLock.lock()

        let cameraBuffer =
            latestCameraPixelBuffer

        cameraFrameLock.unlock()

        guard let cameraBuffer =
            cameraBuffer else {

            return baseImage
        }

        var cameraImage =
            CIImage(
                cvPixelBuffer:
                    cameraBuffer
            )

        let cameraExtent =
    cameraImage.extent

        if getCameraExpandedState() {

            let sourceAspect =
                cameraExtent.width /
                cameraExtent.height

            let targetAspect =
                outputWidth /
                outputHeight

            let cropWidth: CGFloat
            let cropHeight: CGFloat

            if sourceAspect > targetAspect {
                cropHeight = cameraExtent.height
                cropWidth = cropHeight * targetAspect
            } else {
                cropWidth = cameraExtent.width
                cropHeight = cropWidth / targetAspect
            }

            let crop =
                CGRect(
                    x:
                        cameraExtent.midX - cropWidth / 2,
                    y:
                        cameraExtent.midY - cropHeight / 2,
                    width: cropWidth,
                    height: cropHeight
                )

            let scale =
                animatedRect.width /
                cropWidth

            let expandedCamera =
                cameraImage
                    .cropped(to: crop)
                    .transformed(
                        by:
                            CGAffineTransform(
                                translationX:
                                    -crop.origin.x,
                                y:
                                    -crop.origin.y
                            )
                    )
                    .transformed(
                        by:
                            CGAffineTransform(
                                scaleX: scale,
                                y: scale
                            )
                    )
                    .transformed(
                        by:
                            CGAffineTransform(
                                translationX:
                                    animatedRect.origin.x,
                                y:
                                    outputHeight -
                                    animatedRect.origin.y -
                                    animatedRect.height
                            )
                    )

            return expandedCamera.composited(
                over:
                    baseImage
            )
        }




// MARK: Normal Circular Camera

let side =
    min(
        cameraExtent.width,
        cameraExtent.height
    )

let squareCrop =
    CGRect(
        x:
            cameraExtent.midX -
            side / 2,
        y:
            cameraExtent.midY -
            side / 2,
        width:
            side,
        height:
            side
    )

cameraImage =
    cameraImage
        .cropped(
            to:
                squareCrop
        )
        .transformed(
            by:
                CGAffineTransform(
                    translationX:
                        -squareCrop.origin.x,
                    y:
                        -squareCrop.origin.y
                )
        )

let diameter =
    min(
        animatedRect.width,
        animatedRect.height
    )

        let radius: CGFloat =
    diameter / 2

        let bubbleFrame =
            CGRect(
                x:
                    0,
                y:
                    0,
                width:
                    diameter,
                height:
                    diameter
            )

        // Scale camera

        let cameraScale =
            diameter /
            side

        cameraImage =
            cameraImage.transformed(
                by:
                    CGAffineTransform(
                        scaleX:
                            cameraScale,
                        y:
                            cameraScale
                    )
            )


        if getCameraExpandedState() {

            let flippedY =
                outputHeight -
                animatedRect.origin.y -
                diameter

            let expandedCamera =
                cameraImage.transformed(
                    by:
                        CGAffineTransform(
                            translationX:
                                animatedRect.origin.x,
                            y:
                                flippedY
                        )
                )

            return expandedCamera.composited(
                over:
                    baseImage
            )
        }


        // MARK: Camera Circular Mask

        guard let maskFilter =
                CIFilter(
                    name:
                        "CIRadialGradient"
                ) else {

            return baseImage
        }

        maskFilter.setValue(
            CIVector(
                x:
                    radius,
                y:
                    radius
            ),
            forKey:
                "inputCenter"
        )

        maskFilter.setValue(
            max(
                radius - 1,
                0
            ),
            forKey:
                "inputRadius0"
        )

        maskFilter.setValue(
            radius,
            forKey:
                "inputRadius1"
        )

        maskFilter.setValue(
            CIColor.white,
            forKey:
                "inputColor0"
        )

        maskFilter.setValue(
            CIColor.clear,
            forKey:
                "inputColor1"
        )

        guard let circularMask =
            maskFilter.outputImage?
                .cropped(
                    to:
                        bubbleFrame
                ) else {

            return baseImage
        }

        guard let blendFilter =
                CIFilter(
                    name:
                        "CIBlendWithMask"
                ) else {

            return baseImage
        }

        blendFilter.setValue(
            cameraImage,
            forKey:
                kCIInputImageKey
        )

        blendFilter.setValue(
            circularMask,
            forKey:
                kCIInputMaskImageKey
        )

        guard var maskedCamera =
            blendFilter.outputImage else {

            return baseImage
        }

        // MARK: True Circular Green Border

        let borderWidth: CGFloat =
    max(
        diameter * 0.025,
        CGFloat(3)
    )

        // Green source

        let greenImage =
            CIImage(
                color:
                    CIColor(
                        red:
                            0,
                        green:
                            1,
                        blue:
                            0,
                        alpha:
                            1
                    )
            )
            .cropped(
                to:
                    bubbleFrame
            )

        // Outer circle

        guard let outerFilter =
                CIFilter(
                    name:
                        "CIRadialGradient"
                ) else {

            return baseImage
        }

        outerFilter.setValue(
            CIVector(
                x:
                    radius,
                y:
                    radius
            ),
            forKey:
                "inputCenter"
        )

        outerFilter.setValue(
            max(
                radius - 0.5,
                0
            ),
            forKey:
                "inputRadius0"
        )

        outerFilter.setValue(
            radius,
            forKey:
                "inputRadius1"
        )

        outerFilter.setValue(
            CIColor.white,
            forKey:
                "inputColor0"
        )

        outerFilter.setValue(
            CIColor.clear,
            forKey:
                "inputColor1"
        )

        guard let outerCircle =
            outerFilter.outputImage?
                .cropped(
                    to:
                        bubbleFrame
                ) else {

            return baseImage
        }

        // Inner circle

        guard let innerFilter =
                CIFilter(
                    name:
                        "CIRadialGradient"
                ) else {

            return baseImage
        }

        let innerRadius: CGFloat =
    max(
        radius -
            borderWidth,
        CGFloat(0)
    )

        innerFilter.setValue(
            CIVector(
                x:
                    radius,
                y:
                    radius
            ),
            forKey:
                "inputCenter"
        )

        innerFilter.setValue(
            max(
                innerRadius - 0.5,
                0
            ),
            forKey:
                "inputRadius0"
        )

        innerFilter.setValue(
            innerRadius,
            forKey:
                "inputRadius1"
        )

        innerFilter.setValue(
            CIColor.white,
            forKey:
                "inputColor0"
        )

        innerFilter.setValue(
            CIColor.clear,
            forKey:
                "inputColor1"
        )

        guard let innerCircle =
            innerFilter.outputImage?
                .cropped(
                    to:
                        bubbleFrame
                ) else {

            return baseImage
        }

        // Create ring using subtraction

        guard let differenceFilter =
                CIFilter(
                    name:
                        "CIDifferenceBlendMode"
                ) else {

            return baseImage
        }

        differenceFilter.setValue(
            outerCircle,
            forKey:
                kCIInputImageKey
        )

        differenceFilter.setValue(
            innerCircle,
            forKey:
                kCIInputBackgroundImageKey
        )

        guard let ringMask =
            differenceFilter.outputImage?
                .cropped(
                    to:
                        bubbleFrame
                ) else {

            return baseImage
        }

        // Apply ring mask

        guard let ringBlend =
                CIFilter(
                    name:
                        "CIBlendWithMask"
                ) else {

            return baseImage
        }

        ringBlend.setValue(
            greenImage,
            forKey:
                kCIInputImageKey
        )

        ringBlend.setValue(
            ringMask,
            forKey:
                kCIInputMaskImageKey
        )

        guard let greenRing =
            ringBlend.outputImage?
                .cropped(
                    to:
                        bubbleFrame
                ) else {

            return baseImage
        }

        // Put border over camera

        maskedCamera =
            greenRing.composited(
                over:
                    maskedCamera
            )

        // MARK: Position Camera

let flippedY =
    outputHeight -
    animatedRect.origin.y -
    diameter

        maskedCamera =
            maskedCamera.transformed(
                by:
                    CGAffineTransform(
                        translationX:
                            animatedRect.origin.x,
                        y:
                            flippedY
                    )
            )

        return maskedCamera.composited(
            over:
                baseImage
        )
    }

        // MARK: - Camera Output

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {

        // Camera

        if output === cameraVideoOutput {

            if let imageBuffer = sampleBuffer.imageBuffer {

                cameraFrameLock.lock()

                latestCameraPixelBuffer = imageBuffer

                cameraFrameLock.unlock()
            }

            return
        }

        // Microphone

        guard isWriting,
              let writer = videoWriter,
              isSessionStarted,
              let sessionStart = baseStartTime,
              sampleBuffer.presentationTimeStamp >= sessionStart,
              writer.status == .writing else {
            return
        }

        if let audioInput = audioWriterInput,
           audioInput.isReadyForMoreMediaData {

            audioInput.append(sampleBuffer)
        }
    }
}