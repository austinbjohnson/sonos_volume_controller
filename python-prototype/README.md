# Python Prototype (Fully Functional)

This is the original Python implementation of Sonos Volume Controller. It's fully functional and ready to use, but cannot be distributed via the Mac App Store.

## Features

- Menu bar app using `rumps`
- Sonos device discovery via `soco` library
- Hotkey support (Fn+F11/F12) for volume control
- Visual HUD showing volume changes
- Persistent settings via UserDefaults
- Audio device monitoring

## Installation

### 1. Install dependencies:

```bash
cd python-prototype
pip3 install -r requirements.txt
```

### 2. Grant Accessibility Permissions:

- Open **System Settings** > **Privacy & Security** > **Accessibility**
- Add Python (or Terminal) to the list of allowed apps
- This is required for hotkey interception

### 3. Run the app:

```bash
python3 sonos_volume_controller.py
```

## Files

- `sonos_volume_controller.py` - Main application (use this one)
- `volume_key_listener.py` - Early prototype of key listener
- `media_key_tap.py` - Experimental media key tap implementation
- `requirements.txt` - Python dependencies

## Why Python?

The Python version was created first because:
- Faster prototyping with `rumps` and `soco` libraries
- No Xcode/toolchain issues
- Easier to test and iterate

## Limitations

- Cannot be distributed via Mac App Store (requires Python runtime)
- Requires users to install Python dependencies
- Larger memory footprint than native Swift
- No code signing/notarization for easy distribution

## Migrating to Swift

The Swift version in `../SonosVolumeController/` is being developed for App Store distribution. It reimplements all functionality in native Swift/Cocoa.