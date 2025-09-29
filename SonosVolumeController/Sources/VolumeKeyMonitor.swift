import Cocoa
import CoreGraphics

class VolumeKeyMonitor {
    private let audioMonitor: AudioDeviceMonitor
    private let sonosController: SonosController
    private let settings: AppSettings
    private var eventTap: CFMachPort?

    init(audioMonitor: AudioDeviceMonitor, sonosController: SonosController, settings: AppSettings) {
        self.audioMonitor = audioMonitor
        self.sonosController = sonosController
        self.settings = settings
    }

    func start() {
        // Request accessibility permissions if needed
        // Swift 6 workaround: this constant is safe to access despite warning
        let trusted = AXIsProcessTrustedWithOptions(nil)

        if !trusted {
            print("⚠️ Please grant accessibility permissions in System Settings > Privacy & Security > Accessibility")
            return
        }

        setupEventTap()
    }

    private func setupEventTap() {
        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue) |
                        (1 << CGEventType.tapDisabledByTimeout.rawValue) |
                        (1 << CGEventType.tapDisabledByUserInput.rawValue)

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<VolumeKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Failed to create event tap")
            return
        }

        self.eventTap = eventTap

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        print("Volume key monitor started")
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent> {
        // Re-enable tap if it was disabled
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            print("⚠️ Event tap was disabled, re-enabling...")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                print("✅ Event tap re-enabled")
            }
            return Unmanaged.passUnretained(event)
        }

        // Only process key down events
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // F11/F12 key codes on macOS
        // F11 (Volume Down): 103, F12 (Volume Up): 111
        let isVolumeKey = keyCode == 103 || keyCode == 111

        // Debug: print all F-key presses
        if keyCode >= 100 && keyCode <= 120 {
            print("🔑 Key pressed: \(keyCode)")
        }

        guard isVolumeKey else {
            return Unmanaged.passUnretained(event)
        }

        print("🎹 F11/F12 detected! Checking if should intercept...")
        print("   Current device: \(audioMonitor.currentDeviceName)")
        print("   Should intercept: \(audioMonitor.shouldInterceptVolumeKeys)")
        print("   Settings enabled: \(settings.enabled)")

        // Check if we should intercept
        guard audioMonitor.shouldInterceptVolumeKeys else {
            print("   ❌ Not intercepting - wrong audio device")
            // Pass through to system
            return Unmanaged.passUnretained(event)
        }

        // Intercept and handle with Sonos
        print("✅ Intercepting and consuming event")
        switch keyCode {
        case 111: // F12 - Volume Up
            print("🔊 F12 (Volume Up) - Controlling Sonos")
            sonosController.volumeUp()
        case 103: // F11 - Volume Down
            print("🔉 F11 (Volume Down) - Controlling Sonos")
            sonosController.volumeDown()
        default:
            break
        }

        // Consume the event by returning the same event but flagged
        // This prevents it from reaching other apps
        event.flags = []
        return Unmanaged.passUnretained(event)
    }
}