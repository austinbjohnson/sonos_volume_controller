import Cocoa
import CoreAudio

@available(macOS 26.0, *)
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var audioMonitor: AudioDeviceMonitor!
    var volumeKeyMonitor: VolumeKeyMonitor!
    var sonosController: SonosController!
    var settings: AppSettings!
    var preferencesWindow: PreferencesWindow!
    var menuBarPopover: MenuBarPopover!
    var permissionCheckTimer: Timer?
    var permissionCheckStartTime: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 Application did finish launching")
        // Initialize settings
        settings = AppSettings()
        print("✅ Settings initialized")

        // Check accessibility permissions on first launch
        checkAccessibilityPermissions()

        // Initialize preferences window
        preferencesWindow = PreferencesWindow(appDelegate: self)

        // Initialize popover
        menuBarPopover = MenuBarPopover(appDelegate: self)

        // Create status bar item with custom Sonos speaker icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // Create custom Sonos speaker icon programmatically
            let iconImage = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                // Speaker body (rounded rectangle)
                let bodyRect = NSRect(x: 4, y: 1, width: 10, height: 16)
                let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 1.5, yRadius: 1.5)
                bodyPath.lineWidth = 1.2
                NSColor.black.setStroke()
                bodyPath.stroke()

                // Speaker grille lines
                for y in stride(from: 4.0, through: 14.0, by: 2.0) {
                    let line = NSBezierPath()
                    line.move(to: NSPoint(x: 5.5, y: y))
                    line.line(to: NSPoint(x: 12.5, y: y))
                    line.lineWidth = 0.8
                    line.lineCapStyle = .round
                    NSColor.black.setStroke()
                    line.stroke()
                }

                // Small circle at bottom (Sonos indicator)
                let circle = NSBezierPath(ovalIn: NSRect(x: 8.4, y: 14.9, width: 1.2, height: 1.2))
                NSColor.black.setFill()
                circle.fill()

                return true
            }
            iconImage.isTemplate = true  // Adapts to dark/light menu bar
            button.image = iconImage
            button.target = self
            button.action = #selector(togglePopover)
            print("🔊 Menu bar icon: Custom Sonos speaker")
        }
        print("📍 Status bar item created")

        // Initialize components
        audioMonitor = AudioDeviceMonitor(settings: settings)
        sonosController = SonosController(settings: settings)
        volumeKeyMonitor = VolumeKeyMonitor(
            audioMonitor: audioMonitor,
            sonosController: sonosController,
            settings: settings
        )

        // Start monitoring
        audioMonitor.start()
        volumeKeyMonitor.start()

        // Listen for device discovery completion
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(devicesDiscovered),
            name: NSNotification.Name("SonosDevicesDiscovered"),
            object: nil
        )

        // Listen for network errors (permissions issues)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNetworkError(_:)),
            name: NSNotification.Name("SonosNetworkError"),
            object: nil
        )

        // Discover Sonos devices with completion handler for proper initialization
        print("🔍 Starting Sonos discovery...")
        Task {
            await sonosController.discoverDevices { [weak self] in
                guard let self = self else { return }

                // Auto-select default speaker AFTER topology is loaded
                Task { @MainActor in
                    if !self.settings.selectedSonosDevice.isEmpty {
                        print("🎵 Auto-selecting default speaker (after topology loaded): \(self.settings.selectedSonosDevice)")
                        await self.sonosController.selectDevice(name: self.settings.selectedSonosDevice)

                        // Fetch and sync current volume from the selected speaker
                        print("🔊 Fetching current volume from default speaker...")
                        await self.sonosController.getVolume { @Sendable volume in
                            print("🔊 Initial volume: \(volume)%")
                            // Post notification to update UI
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(
                                    name: NSNotification.Name("SonosVolumeDidChange"),
                                    object: nil,
                                    userInfo: ["volume": volume]
                                )
                            }
                        }
                    } else {
                        print("⚠️ No default speaker configured")

                        // First launch - show popover to guide user to select a speaker
                        print("👋 First launch detected - showing onboarding popover")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            guard let button = self.statusItem.button else { return }
                            self.menuBarPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                        }
                    }

                    print("✅ Sonos discovery and topology loaded")

                    // Start real-time topology monitoring
                    Task {
                        do {
                            try await self.sonosController.startTopologyMonitoring()
                        } catch {
                            print("⚠️ Failed to start topology monitoring: \(error)")
                            print("   Falling back to manual topology updates")
                        }
                    }
                }
            }
        }

        print("✅ Sonos Volume Controller started")
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        menuBarPopover.toggle(from: button)
    }

    @objc func devicesDiscovered() {
        print("📱 Devices discovered, updating popover...")
        // Just refresh UI - device selection happens in completion handler
        menuBarPopover.refresh()
    }

    @objc func handleNetworkError(_ notification: Notification) {
        // Only show alert once per session (same flag as accessibility to avoid alert spam)
        guard !settings.hasShownPermissionPrompt else { return }

        let alert = NSAlert()
        alert.messageText = "Network Access Required"
        alert.informativeText = """
        Sonos Volume Controller needs local network access to discover and control your Sonos speakers.

        If you denied the network permission prompt, you can grant it in:
        System Settings > Privacy & Security > Local Network

        Then restart the app.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()

        // Mark as shown to avoid showing multiple permission-related alerts per session
        settings.hasShownPermissionPrompt = true
    }

    // MARK: - Accessibility Permissions

    func checkAccessibilityPermissions() {
        // Always check if accessibility is granted
        let trusted = AXIsProcessTrusted()
        if trusted {
            return
        }

        // Not trusted - show prompt if we haven't shown it this session
        if settings.hasShownPermissionPrompt {
            // Already prompted this session, just log
            print("⚠️ Accessibility permissions not granted. Volume hotkeys will not work.")
            print("   Grant permissions in System Settings > Privacy & Security > Accessibility")
            return
        }

        // Show prompt and mark as shown for this session
        showAccessibilityPrompt()
        settings.hasShownPermissionPrompt = true
    }

    private func showAccessibilityPrompt() {
        let alert = NSAlert()
        alert.messageText = "Permissions Required"
        alert.informativeText = """
        Sonos Volume Controller needs two permissions to work:

        1. Accessibility - to capture volume hotkeys (F11/F12)
        2. Local Network - to discover and control Sonos speakers

        Click "Open System Settings" to grant accessibility permission. You'll also be prompted for network access when the app tries to discover speakers.

        After granting accessibility permission, you'll need to restart the app.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
            // Start checking if permission was granted
            startPermissionMonitoring()
        }
    }

    private func openAccessibilitySettings() {
        // Open System Settings to Privacy & Security > Accessibility
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startPermissionMonitoring() {
        // Stop any existing timer
        permissionCheckTimer?.invalidate()

        // Track start time
        permissionCheckStartTime = Date()

        // Check every 2 seconds for up to 2 minutes
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }

                // Check if permission was granted
                if AXIsProcessTrusted() {
                    self.permissionCheckTimer?.invalidate()
                    self.showRestartPrompt()
                    return
                }

                // Stop checking after 2 minutes
                if let startTime = self.permissionCheckStartTime,
                   Date().timeIntervalSince(startTime) > 120 {
                    self.permissionCheckTimer?.invalidate()
                    print("⏱️ Permission monitoring timed out")
                }
            }
        }
    }

    private func showRestartPrompt() {
        let alert = NSAlert()
        alert.messageText = "Permission Granted!"
        alert.informativeText = """
        Accessibility permission has been granted.

        The app needs to restart for the changes to take effect. Restart now?
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Restart the app
            restartApp()
        }
    }

    private func restartApp() {
        let appPath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [appPath]

        try? task.run()

        // Quit current instance
        NSApplication.shared.terminate(nil)
    }
}

// Entry point - must be at the very end
print("🎬 Starting app...")
autoreleasepool {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // Menu bar app (no dock icon)
    print("📱 Activation policy set")

    if #available(macOS 26.0, *) {
        let delegate = AppDelegate()
        print("👤 Delegate created")
        app.delegate = delegate
        print("🔗 Delegate assigned, running app...")
        app.run()
    } else {
        print("❌ This app requires macOS 26.0 (Tahoe) or later for Liquid Glass support")
    }
}