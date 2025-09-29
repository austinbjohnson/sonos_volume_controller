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
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)

        if !trusted {
            print("⚠️ Please grant accessibility permissions in System Settings > Privacy & Security > Accessibility")
            return
        }

        setupEventTap()
    }

    private func setupEventTap() {
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

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
        // Only process key down events
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Volume key codes on macOS
        // Volume Up: 72, Volume Down: 73, Mute: 74
        let isVolumeKey = keyCode == 72 || keyCode == 73 || keyCode == 74

        guard isVolumeKey else {
            return Unmanaged.passUnretained(event)
        }

        // Check if we should intercept
        guard audioMonitor.shouldInterceptVolumeKeys else {
            // Pass through to system
            return Unmanaged.passUnretained(event)
        }

        // Intercept and handle with Sonos
        switch keyCode {
        case 72: // Volume Up
            print("Volume Up - Controlling Sonos")
            sonosController.volumeUp()
        case 73: // Volume Down
            print("Volume Down - Controlling Sonos")
            sonosController.volumeDown()
        case 74: // Mute
            print("Mute - Controlling Sonos")
            sonosController.toggleMute()
        default:
            break
        }

        // Return nil to consume the event (don't pass to system)
        return Unmanaged.passUnretained(CGEvent(source: nil)!)
    }
}