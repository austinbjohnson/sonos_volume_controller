import Foundation
import ServiceManagement

@MainActor
class LoginItemManager {
    static let shared = LoginItemManager()

    private init() {}

    /// Check if the app is registered to run at login
    var isEnabled: Bool {
        get {
            SMAppService.mainApp.status == .enabled
        }
    }

    /// Enable or disable launch at login
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            // Register the app to launch at login
            if SMAppService.mainApp.status == .enabled {
                print("✅ Already registered for login")
                return
            }

            try SMAppService.mainApp.register()
            print("✅ Registered to run at login")
        } else {
            // Unregister from login items
            if SMAppService.mainApp.status == .notRegistered {
                print("✅ Already not registered")
                return
            }

            try SMAppService.mainApp.unregister()
            print("✅ Unregistered from login items")
        }
    }

    /// Get detailed status information
    var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return "Not registered"
        case .enabled:
            return "Enabled"
        case .requiresApproval:
            return "Requires approval (check System Settings > General > Login Items)"
        case .notFound:
            return "Not found (app must be in /Applications or build as .app bundle)"
        @unknown default:
            return "Unknown status"
        }
    }
}