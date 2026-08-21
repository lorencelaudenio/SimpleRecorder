# Simple Screen Recorder for MacOS

SimpleRecorder is a lightweight macOS menu bar app for recording your screen with optional microphone audio and a floating camera view. It also provides activity-based zoom and click effects for clearer demonstrations.

## Requirements

- macOS 12.3 or later
- Swift compiler and macOS command line developer tools
- An `AppIcon.icns` file in the project root for the packaged build

## Build

Run the build script from the project root:

```sh
./build.sh
```

The script creates:

- `build/SimpleRecorder.app`
- `build/SimpleRecorder.dmg`

The app is built as an x86_64 binary and ad hoc signed with the included entitlements.

## Permissions

On first launch, macOS may ask for these permissions in System Settings > Privacy & Security:

- Screen Recording
- Accessibility
- Camera
- Microphone

Accessibility permission is used for activity tracking and zoom behavior. Camera and microphone capture are optional, but require their respective permissions when enabled.

## Controls

- `Command + Shift + R`: Start or stop recording from any app
- Camera expand button: Expand the floating camera view while recording
- `Escape`: Return an expanded camera view to its floating state

## Project Layout

- `Sources/main.swift`: Application and recording implementation
- `Info.plist`: App bundle metadata and permission descriptions
- `Entitlements.plist`: App entitlements
- `build.sh`: App and DMG build script
- `RELEASE_NOTES.md`: Release history
