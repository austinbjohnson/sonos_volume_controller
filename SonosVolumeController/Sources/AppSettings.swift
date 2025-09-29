import Foundation

class AppSettings {
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let enabled = "sonosControlEnabled"
        static let triggerDevice = "triggerDeviceName"
        static let selectedSonos = "selectedSonosDevice"
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

    init() {
        // Set default enabled state to true on first launch
        if defaults.object(forKey: Keys.enabled) == nil {
            defaults.set(true, forKey: Keys.enabled)
        }
    }
}