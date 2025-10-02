import Cocoa
import CoreGraphics

class VolumeKeyMonitor: @unchecked Sendable {
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
        let eventFlags = event.flags

        // Convert CGEventFlags to NSEvent.ModifierFlags format for comparison with settings
        // CGEventFlags and NSEvent.ModifierFlags have different raw values, so we need to map them
        var convertedModifiers: UInt = 0
        if eventFlags.contains(.maskCommand) {
            convertedModifiers |= NSEvent.ModifierFlags.command.rawValue
        }
        if eventFlags.contains(.maskAlternate) {
            convertedModifiers |= NSEvent.ModifierFlags.option.rawValue
        }
        if eventFlags.contains(.maskShift) {
            convertedModifiers |= NSEvent.ModifierFlags.shift.rawValue
        }
        if eventFlags.contains(.maskControl) {
            convertedModifiers |= NSEvent.ModifierFlags.control.rawValue
        }

        // Get custom hotkeys from settings
        let volumeDownKey = settings.volumeDownKeyCode
        let volumeUpKey = settings.volumeUpKeyCode
        let volumeDownModifiers = settings.volumeDownModifiers
        let volumeUpModifiers = settings.volumeUpModifiers

        // Check if this matches our volume hotkeys (key code + modifiers)
        let isVolumeDownKey = (keyCode == volumeDownKey) && (convertedModifiers == volumeDownModifiers)
        let isVolumeUpKey = (keyCode == volumeUpKey) && (convertedModifiers == volumeUpModifiers)
        let isVolumeKey = isVolumeDownKey || isVolumeUpKey

        // Debug: print key presses for common keys
        if keyCode >= 100 && keyCode <= 120 {
            print("🔑 Key pressed: \(keyCode)")
        }

        guard isVolumeKey else {
            return Unmanaged.passUnretained(event)
        }

        print("🎹 Volume hotkey detected! Checking if should intercept...")
        print("   Current device: \(audioMonitor.currentDeviceName)")
        print("   Should intercept: \(audioMonitor.shouldInterceptVolumeKeys)")
        print("   Settings enabled: \(settings.enabled)")

        // Check if we should intercept
        guard audioMonitor.shouldInterceptVolumeKeys else {
            print("   ❌ Not intercepting - wrong audio device")

            // Show notification explaining why volume control didn't work
            // Capture trigger device name before entering Task to avoid data race
            let triggerDevice = settings.triggerDeviceName
            Task { @MainActor in
                VolumeHUD.shared.showError(
                    title: "Wrong Audio Device",
                    message: "Switch to \(triggerDevice) to control Sonos"
                )
            }

            // Pass through to system
            return Unmanaged.passUnretained(event)
        }

        // Intercept and handle with Sonos
        print("✅ Intercepting event")
        if isVolumeUpKey {
            print("🔊 Volume Up - Controlling Sonos")
            Task {
                await sonosController.volumeUp()
            }
        } else if isVolumeDownKey {
            print("🔉 Volume Down - Controlling Sonos")
            Task {
                await sonosController.volumeDown()
            }
        }

        // Pass through - we've handled it but can't truly suppress F-keys
        return Unmanaged.passUnretained(event)
    }
}