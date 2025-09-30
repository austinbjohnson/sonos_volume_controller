# Sonos Volume Controller

Control your Sonos speakers with macOS hotkeys (F11/F12) when a specific audio device is active.

## 🎯 Project Status

This project has **two implementations**:

### 🐍 Python Version (Fully Functional)
📁 **Location**: [`python-prototype/`](python-prototype/)

✅ Production-ready, works out of the box
❌ Cannot be distributed via Mac App Store

[**→ Python Installation Instructions**](python-prototype/README.md)

### 🍎 Swift Version (In Development)
📁 **Location**: [`SonosVolumeController/`](SonosVolumeController/)

🚧 Being developed for Mac App Store distribution
⚠️ Currently has toolchain compatibility issues
🎯 Goal: Native macOS app with App Store distribution

---

## Features

- 🎯 **Conditional Interception**: Only controls Sonos when a specific audio device (e.g., your monitor) is active
- 🎹 **Hotkey Control**: Use Fn+F11 (Down) / Fn+F12 (Up) to control volume
- 🖥️ **Menu Bar App**: Easy access to settings and device selection
- 🔍 **Auto-Discovery**: Automatically finds Sonos speakers on your network
- 💾 **Pass-Through**: Normal macOS volume control works when using headphones or other audio devices
- 📊 **Visual HUD**: On-screen volume display (Python version)

## Quick Start (Python)

```bash
# Install dependencies
cd python-prototype
pip3 install -r requirements.txt

# Run the app
python3 sonos_volume_controller.py
```

**Note**: You'll need to grant Accessibility permissions in System Settings.

## Project Structure

```
sonos_volume_controller/
├── README.md                    # This file
├── python-prototype/            # Python implementation (works now)
│   ├── README.md
│   ├── sonos_volume_controller.py
│   └── requirements.txt
└── SonosVolumeController/       # Swift implementation (App Store ready)
    ├── Package.swift
    ├── Sources/
    └── build.sh
```

## Why Two Versions?

**Python**: Fast prototyping, proven to work, uses great libraries (`rumps`, `soco`)
**Swift**: Native performance, App Store distribution, better macOS integration

## Roadmap

- [x] Python prototype with full functionality
- [x] Swift implementation started
- [ ] Fix Swift toolchain issues
- [ ] Complete Swift Sonos UPnP client
- [ ] Match Python feature parity in Swift
- [ ] App Store submission preparation
- [ ] Code signing & notarization
- [ ] Mac App Store launch

## Contributing

This is a personal project, but suggestions and issues are welcome!

The official sonos api docs used are here: https://docs.sonos.com/docs/control-sonos-players