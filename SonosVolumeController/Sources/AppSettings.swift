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
        static let hasShownAccessibilityPrompt = "hasShownAccessibilityPrompt"
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
            return value == 0 ? 25 : value  // Default to 9 (25)
        }
        set {
            defaults.set(newValue, forKey: Keys.volumeDownKeyCode)
        }
    }

    var volumeUpKeyCode: Int {
        get {
            let value = defaults.integer(forKey: Keys.volumeUpKeyCode)
            return value == 0 ? 29 : value  // Default to 0 (29)
        }
        set {
            defaults.set(newValue, forKey: Keys.volumeUpKeyCode)
        }
    }

    var volumeDownModifiers: UInt {
        get {
            let value = defaults.integer(forKey: Keys.volumeDownModifiers)
            // Default to Cmd+Shift
            return value == 0 ? (NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue) : UInt(value)
        }
        set {
            defaults.set(Int(newValue), forKey: Keys.volumeDownModifiers)
        }
    }

    var volumeUpModifiers: UInt {
        get {
            let value = defaults.integer(forKey: Keys.volumeUpModifiers)
            // Default to Cmd+Shift
            return value == 0 ? (NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue) : UInt(value)
        }
        set {
            defaults.set(Int(newValue), forKey: Keys.volumeUpModifiers)
        }
    }

    var hasShownAccessibilityPrompt: Bool {
        get {
            defaults.bool(forKey: Keys.hasShownAccessibilityPrompt)
        }
        set {
            defaults.set(newValue, forKey: Keys.hasShownAccessibilityPrompt)
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
        // Set default hotkeys (Cmd+Shift+9/0) on first launch
        if defaults.object(forKey: Keys.volumeDownKeyCode) == nil {
            defaults.set(25, forKey: Keys.volumeDownKeyCode)  // 9
        }
        if defaults.object(forKey: Keys.volumeUpKeyCode) == nil {
            defaults.set(29, forKey: Keys.volumeUpKeyCode)  // 0
        }
        if defaults.object(forKey: Keys.volumeDownModifiers) == nil {
            let cmdShift = Int(NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue)
            defaults.set(cmdShift, forKey: Keys.volumeDownModifiers)
        }
        if defaults.object(forKey: Keys.volumeUpModifiers) == nil {
            let cmdShift = Int(NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue)
            defaults.set(cmdShift, forKey: Keys.volumeUpModifiers)
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