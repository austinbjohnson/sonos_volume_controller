import Foundation

class AppSettings {
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let enabled = "sonosControlEnabled"
        static let triggerDevice = "triggerDeviceName"
        static let selectedSonos = "selectedSonosDevice"
        static let volumeStep = "volumeStep"
    }

    var enabled: Bool {
        get {
            defaults.bool(forKey: Keys.enabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.enabled)
            print("Sonos control \(newValue ? "enabled" : "disabled")")
        }
    }

    var triggerDeviceName: String {
        get {
            defaults.string(forKey: Keys.triggerDevice) ?? "DELL U2723QE"
        }
        set {
            defaults.set(newValue, forKey: Keys.triggerDevice)
            print("Trigger device set to: \(newValue)")
        }
    }

    var selectedSonosDevice: String {
        get {
            defaults.string(forKey: Keys.selectedSonos) ?? ""
        }
        set {
            defaults.set(newValue, forKey: Keys.selectedSonos)
        }
    }

    var volumeStep: Int {
        get {
            let value = defaults.integer(forKey: Keys.volumeStep)
            return value == 0 ? 5 : value  // Default to 5 if not set
        }
        set {
            defaults.set(newValue, forKey: Keys.volumeStep)
        }
    }

    init() {
        // Set default enabled state to true on first launch
        if defaults.object(forKey: Keys.enabled) == nil {
            defaults.set(true, forKey: Keys.enabled)
        }
        // Set default volume step to 5 on first launch
        if defaults.object(forKey: Keys.volumeStep) == nil {
            defaults.set(5, forKey: Keys.volumeStep)
        }
    }
}