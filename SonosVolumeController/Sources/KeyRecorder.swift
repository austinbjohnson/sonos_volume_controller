import Cocoa

@MainActor
class KeyRecorder {
    private var eventMonitor: Any?
    private var completion: ((Int) -> Void)?

    /// Start recording a key press
    /// - Parameter completion: Called with the captured key code
    func startRecording(completion: @escaping (Int) -> Void) {
        self.completion = completion

        // Set up local event monitor to capture key down events
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            let keyCode = Int(event.keyCode)
            print("🎹 Recorded key code: \(keyCode)")

            // Stop recording
            self.stopRecording()

            // Call completion with the key code
            self.completion?(keyCode)

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