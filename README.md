# Sonos Volume Controller

A native macOS menu bar app for controlling Sonos speakers with hotkeys. Control your Sonos volume using F11/F12 keys, with optional audio device-based triggering.

## Features

- 🎹 **Hotkey Control**: F11/F12 for volume control with visual HUD display
- 🎯 **Smart Triggering**: Optionally activate only when specific audio device is selected (defaults to "Any Device")
- 🖥️ **Menu Bar Integration**: Native macOS menu bar app with popover controls
- 🔍 **Auto-Discovery**: Automatic Sonos speaker detection on local network
- 🎛️ **Speaker Grouping**: Create, manage, and control speaker groups
- 📊 **Hierarchical Group UI**: Expandable group cards to control individual speakers within groups
- ♿ **Accessibility**: First-launch permissions setup with guided onboarding
- 🎨 **Native Design**: Custom Sonos icons and macOS-native UI

## Installation

### Building from Source

```bash
# Build release version
swift build -c release

# Or build and install to /Applications
./build-app.sh --install
```

**Note**: On first launch, you'll be prompted to grant Accessibility permissions in System Settings.

### Running in Development

```bash
swift run
```

## Project Structure

```
sonos_volume_controller/
├── README.md                    # Project overview
├── ROADMAP.md                   # GitHub issues pointer (priorities + status)
├── CHANGELOG.md                 # Version history and completed work
├── CONTRIBUTING.md              # Contribution guidelines
├── DEVELOPMENT.md               # Development workflow and architecture
├── CLAUDE.md                    # AI collaboration guide
└── SonosVolumeController/       # Swift application
    ├── Package.swift
    ├── Sources/
    └── build-app.sh
```

## Contributing

This is a personal project, but suggestions and issues are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on:
- Branch naming conventions
- PR workflow
- How to coordinate with other developers
- Testing requirements

## Resources

- [Official Sonos API Documentation](https://docs.sonos.com/docs/control-sonos-players)
- [GitHub Issues](https://github.com/austinbjohnson/sonos_volume_controller/issues) - Current priorities and known issues
- [CHANGELOG.md](CHANGELOG.md) - Version history and completed improvements
- [DEVELOPMENT.md](DEVELOPMENT.md) - Development workflow and architecture
- [CONTRIBUTING.md](CONTRIBUTING.md) - Contribution guidelines
