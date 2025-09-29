# Swift Development Setup Guide

## After Xcode Installs

### 1. Switch to Xcode toolchain
```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

### 2. Accept Xcode license
```bash
sudo xcodebuild -license accept
```

### 3. Verify Swift setup
```bash
swift --version
xcodebuild -version
```

### 4. Build the Swift project
```bash
cd /Users/ajohnson/Code/abj_volumeController/SonosVolumeController
swift build
```

### 5. Run the app
```bash
swift run
```

---

## Current Swift Project Status

**Location:** `SonosVolumeController/`

**Files:**
- ✅ `Package.swift` - Updated for Swift 6.0
- ✅ `main.swift` - App entry point with menu bar
- ✅ `AppSettings.swift` - UserDefaults persistence
- ✅ `AudioDeviceMonitor.swift` - CoreAudio device detection
- ✅ `VolumeKeyMonitor.swift` - Keyboard event interception
- ⚠️ `SonosController.swift` - Partial UPnP implementation (needs completion)

**Known Issues:**
1. Swift toolchain mismatch (will be fixed by Xcode)
2. Sonos UPnP client incomplete
3. No preferences window yet (need to port from Python)
4. Volume keys use keycodes 72/73/74 (need to change to F11/F12: 103/111)

---

## Next Steps After Build Works

1. **Fix volume key codes** - Change from system volume keys to F11/F12
2. **Complete Sonos UPnP client** - Finish discovery and control
3. **Port preferences window** - Create native Swift UI
4. **Add default speaker feature** - From Python version
5. **Test and refine**
6. **Create .app bundle**
7. **Code signing**
8. **App Store preparation**

---

## Branch Info

Currently on: `swift-development`
Python version safe on: `main`