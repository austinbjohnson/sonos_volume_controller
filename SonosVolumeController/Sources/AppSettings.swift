import Foundation
import Cocoa

class AppSettings {
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let enabled = "sonosControlEnabled"
        static let triggerDevice = "triggerDeviceName"
        static let selectedSonos = "selectedSonosDevice"
        static let volumeStep = "volumeStep"
        static let volumeDownKeyCode = "volumeDownKeyCode"
        static let volumeUpKeyCode = "volumeUpKeyCode"
        static let volumeDownModifiers = "volumeDownModifiers"
        static let volumeUpModifiers = "volumeUpModifiers"
        static let hasShownPermissionPrompt = "hasShownPermissionPrompt"
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

    var volumeDownKeyCode: Int {
        get {
            let value = defaults.integer(forKey: Keys.volumeDownKeyCode)
            return value == 0 ? 103 : value  // Default to F11 (103)
        }
        set {
            defaults.set(newValue, forKey: Keys.volumeDownKeyCode)
        }
    }

    var volumeUpKeyCode: Int {
        get {
            let value = defaults.integer(forKey: Keys.volumeUpKeyCode)
            return value == 0 ? 111 : value  // Default to F12 (111)
        }
        set {
            defaults.set(newValue, forKey: Keys.volumeUpKeyCode)
        }
    }

    var volumeDownModifiers: UInt {
        get {
            // Check if the key exists in defaults
            if defaults.object(forKey: Keys.volumeDownModifiers) == nil {
                return 0  // Default to no modifiers
            }
            return UInt(defaults.integer(forKey: Keys.volumeDownModifiers))
        }
        set {
            defaults.set(Int(newValue), forKey: Keys.volumeDownModifiers)
        }
    }

    var volumeUpModifiers: UInt {
        get {
            // Check if the key exists in defaults
            if defaults.object(forKey: Keys.volumeUpModifiers) == nil {
                return 0  // Default to no modifiers
            }
            return UInt(defaults.integer(forKey: Keys.volumeUpModifiers))
        }
        set {
            defaults.set(Int(newValue), forKey: Keys.volumeUpModifiers)
        }
    }

    var hasShownPermissionPrompt: Bool {
        get {
            defaults.bool(forKey: Keys.hasShownPermissionPrompt)
        }
        set {
            defaults.set(newValue, forKey: Keys.hasShownPermissionPrompt)
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
        // Set default hotkeys (F11/F12 with no modifiers) on first launch
        if defaults.object(forKey: Keys.volumeDownKeyCode) == nil {
            defaults.set(103, forKey: Keys.volumeDownKeyCode)  // F11
        }
        if defaults.object(forKey: Keys.volumeUpKeyCode) == nil {
            defaults.set(111, forKey: Keys.volumeUpKeyCode)  // F12
        }
        if defaults.object(forKey: Keys.volumeDownModifiers) == nil {
            defaults.set(0, forKey: Keys.volumeDownModifiers)  // No modifiers
        }
        if defaults.object(forKey: Keys.volumeUpModifiers) == nil {
            defaults.set(0, forKey: Keys.volumeUpModifiers)  // No modifiers
        }
    }

    /// Get human-readable key name for a key code
    func keyName(for keyCode: Int) -> String {
        // Map common key codes to readable names
        let keyMap: [Int: String] = [
            // Function keys
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            // Volume keys
            72: "Volume Up", 73: "Volume Down", 74: "Mute",
            // Arrow keys
            123: "←", 124: "→", 125: "↓", 126: "↑",
            // Special keys
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
            // Number keys
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
            22: "6", 26: "7", 28: "8", 25: "9", 29: "0"
        ]
        return keyMap[keyCode] ?? "Key \(keyCode)"
    }

    /// Get human-readable key combination string
    func keyComboName(for keyCode: Int, modifiers: UInt) -> String {
        var parts: [String] = []

        // Add modifier symbols
        if modifiers & NSEvent.ModifierFlags.control.rawValue != 0 {
            parts.append("⌃")
        }
        if modifiers & NSEvent.ModifierFlags.option.rawValue != 0 {
            parts.append("⌥")
        }
        if modifiers & NSEvent.ModifierFlags.shift.rawValue != 0 {
            parts.append("⇧")
        }
        if modifiers & NSEvent.ModifierFlags.command.rawValue != 0 {
            parts.append("⌘")
        }

        // Add key name
        parts.append(keyName(for: keyCode))

        return parts.joined()
    }
}