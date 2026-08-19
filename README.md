# Scope — Screen Recorder for macOS Monterey

## Build
```bash
chmod +x build.sh
./build.sh
```

## Requirements
- macOS 12.3+ (Monterey or later)
- Xcode Command Line Tools installed (`xcode-select --install`)

## First run
Scope needs Screen Recording, Camera, and Microphone permissions.
macOS will prompt you the first time — if it doesn't, grant them manually
in System Settings → Privacy & Security.

## Note on signing
This build isn't notarized/signed with an Apple Developer ID. If Gatekeeper
blocks it, right-click the app → Open, or allow it under
System Settings → Privacy & Security → Security.
