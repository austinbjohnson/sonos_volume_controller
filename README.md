# Sonos Volume Controller

Control your Sonos speakers with macOS volume keys when a specific audio device is active.

## Features

- 🎯 **Conditional Interception**: Only controls Sonos when your monitor (DELL U2723QE) is the active audio output
- 🔊 **Volume Keys**: Volume Up/Down/Mute buttons control your Sonos
- 🖥️ **Menu Bar App**: Easy access to settings and device selection
- 🔍 **Auto-Discovery**: Automatically finds Sonos speakers on your network
- 💾 **Pass-Through**: Normal macOS volume control works when using headphones or other audio devices

## Installation

### 1. Install dependencies:

```bash
pip3 install -r requirements.txt
```

### 2. Grant Accessibility Permissions:

- Open **System Settings** > **Privacy & Security** > **Accessibility**
- Add Python (or Terminal) to the list of allowed apps
- This is required for volume key interception

### 3. Run the app:

```bash
python3 sonos_volume_controller.py
```

## Usage

1. The app will appear in your menu bar with a 🔊 icon
2. Click the icon to:
   - See current audio device
   - Enable/disable Sonos control
   - Select which Sonos speaker to control
   - Configure trigger device name
3. When the trigger device (your monitor) is active, volume keys will control the selected Sonos speaker
4. When headphones or other devices are active, volume keys work normally

## Configuration

- **Trigger Device**: The audio device name that activates Sonos control (default: "DELL U2723QE")
- **Volume Step**: Volume change per key press (default: 5%)
- **Enable/Disable**: Toggle Sonos control on/off

## Troubleshooting

### Volume keys not working:
- Make sure accessibility permissions are granted
- Check that the correct trigger device name is configured
- Verify a Sonos speaker is selected

### Can't find Sonos devices:
- Make sure Sonos speakers are on the same WiFi network
- Click "Refresh Devices" in the menu
- Check your firewall isn't blocking UPnP/SSDP

### App not responding:
- Check the terminal for error messages
- Verify Python dependencies are installed

## How It Works

1. **Audio Device Monitor**: Continuously checks the current macOS audio output device
2. **Volume Key Listener**: Intercepts keyboard events for volume keys
3. **Conditional Logic**: Only sends commands to Sonos when:
   - Sonos control is enabled
   - Current audio device matches trigger device
   - A Sonos speaker is selected
4. **Sonos Control**: Uses the Sonos UPnP API to adjust speaker volume

## Making it Start at Login

To run automatically at login:

1. Create a launch agent plist file
2. Or add the script to your Login Items in System Settings

## Notes

- The Swift version is in the `Sources/` directory but has toolchain issues with the current macOS/Swift setup
- The Python version is fully functional and easier to maintain
- Volume changes are applied directly to the Sonos speaker hardware (not software volume)
