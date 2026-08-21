# Release Notes

## SimpleRecorder 1.0

### Added

- Global recording shortcut: `Command + Shift + R` starts and stops recording from any app.
- Floating-camera expand button available during recording.
- Camera expansion renders as a full-screen 16:9 view without stretching.
- `Escape` globally returns the expanded camera to its normal floating state.
- Activity-based zoom that follows clicks, mouse movement, highlighting, and typing.
- Zoom automatically returns to full screen after one second of inactivity and reactivates when activity resumes.
- Explicit Screen Recording, Accessibility, camera, and microphone permission requests.

### Fixed

- Recording finalization now completes even when the screen stream is unavailable during stop.
- Prevented overlapping recording starts while a previous file is finalizing.
- Added writer-state validation and error reporting for failed recordings.
- Filtered audio samples that arrive before the first video session timestamp.
- Recording files now use unique filenames to prevent stop/start overwrites.
- Removed hover-based camera expansion and conflicting browser keyboard shortcuts.
- Reduced mouse-follow zoom latency for smoother tracking.
- Normalized the expanded camera crop to the output's 16:9 aspect ratio.

### Controls

- `Command + Shift + R`: Start or stop recording.
- Camera expand button: Expand the camera while recording.
- `Escape`: Return the expanded camera to its normal state.
