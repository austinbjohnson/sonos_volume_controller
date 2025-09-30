import Cocoa

@MainActor
class KeyRecorder {
    private var eventMonitor: Any?
    private var completion: ((Int, UInt) -> Void)?

    /// Start recording a key press with modifiers
    /// - Parameter completion: Called with the captured key code and modifier flags
    func startRecording(completion: @escaping (Int, UInt) -> Void) {
        self.completion = completion

        // Set up local event monitor to capture key down events
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            let keyCode = Int(event.keyCode)
            let modifierFlags = event.modifierFlags.rawValue

            // Extract only relevant modifier flags (Command, Option, Shift, Control)
            let relevantFlags = modifierFlags & (NSEvent.ModifierFlags.command.rawValue |
                                                 NSEvent.ModifierFlags.option.rawValue |
                                                 NSEvent.ModifierFlags.shift.rawValue |
                                                 NSEvent.ModifierFlags.control.rawValue)

            print("🎹 Recorded key code: \(keyCode), modifiers: \(relevantFlags)")

            // Stop recording
            self.stopRecording()

            // Call completion with the key code and modifiers
            self.completion?(keyCode, relevantFlags)

            // Consume the event (don't pass it through)
            return nil
        }

        print("👂 Listening for keypress...")
    }

    /// Stop recording
    func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
            print("🛑 Stopped listening for keypress")
        }
    }
}