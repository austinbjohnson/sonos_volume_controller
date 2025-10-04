import Cocoa
import CoreGraphics

@MainActor
class HotkeyTester {
    private var testTap: CFMachPort?
    private var testCompletion: ((Bool) -> Void)?
    private var testTimer: Timer?
    private weak var volumeKeyMonitor: VolumeKeyMonitor?
    private let settings: AppSettings
    private var detectedHotkey: Bool = false

    init(volumeKeyMonitor: VolumeKeyMonitor, settings: AppSettings) {
        self.volumeKeyMonitor = volumeKeyMonitor
        self.settings = settings
    }

    /// Test if hotkeys are working by creating a temporary event tap
    /// Calls completion with true if F11/F12 detected, false if test times out
    func testHotkeys(completion: @escaping (Bool) -> Void) {
        print("🧪 Starting hotkey test...")

        // Store completion handler
        self.testCompletion = completion
        self.detectedHotkey = false

        // Pause main monitor to prevent conflicts
        volumeKeyMonitor?.pause()

        // Create test event tap
        let success = createTestTap()

        if !success {
            print("❌ Failed to create test event tap")
            Task { @MainActor in
                self.cleanup(success: false)
            }
            return
        }

        // Set 2-second timeout
        testTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            print("⏱️ Test timeout - no hotkey detected")
            self?.cleanup(success: false)
        }

        print("🧪 Test running... Press F11 or F12")
    }

    private func createTestTap() -> Bool {
        let eventMask = (1 << CGEventType.keyDown.rawValue)

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let tester = Unmanaged<HotkeyTester>.fromOpaque(refcon).takeUnretainedValue()

                Task { @MainActor in
                    tester.handleTestEvent(event: event)
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        self.testTap = eventTap

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        print("✅ Test event tap created")
        return true
    }

    private func handleTestEvent(event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Get configured hotkeys
        let volumeDownKey = settings.volumeDownKeyCode
        let volumeUpKey = settings.volumeUpKeyCode

        // Check if F11 or F12 (or configured hotkeys)
        let isHotkey = (keyCode == volumeDownKey) || (keyCode == volumeUpKey)

        if isHotkey && !detectedHotkey {
            detectedHotkey = true
            print("✅ Hotkey detected: \(keyCode)")
            cleanup(success: true)
        }
    }

    private func cleanup(success: Bool) {
        // Invalidate timer
        testTimer?.invalidate()
        testTimer = nil

        // Disable and remove test tap
        if let tap = testTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Note: CFMachPort is automatically cleaned up
        }
        testTap = nil

        // Resume main monitor
        volumeKeyMonitor?.resume()

        // Call completion handler
        testCompletion?(success)
        testCompletion = nil

        print("🧪 Test cleanup complete (success: \(success))")
    }
}
