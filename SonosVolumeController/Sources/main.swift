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

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 Application did finish launching")
        // Initialize settings
        settings = AppSettings()
        print("✅ Settings initialized")

        // Initialize preferences window
        preferencesWindow = PreferencesWindow(appDelegate: self)

        // Initialize popover
        menuBarPopover = MenuBarPopover(appDelegate: self)

        // Create status bar item with custom Sonos speaker icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // Load custom Sonos speaker icon
            if let iconPath = Bundle.main.path(forResource: "SonosMenuBarIcon", ofType: "svg", inDirectory: "Resources"),
               let image = NSImage(contentsOfFile: iconPath) {
                image.isTemplate = true  // Adapts to dark/light menu bar
                button.image = image
                print("🔊 Menu bar icon: Custom Sonos speaker")
            } else {
                // Fallback to text if icon not found
                button.title = "S"
                button.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
                print("🔊 Menu bar icon: S (fallback)")
            }
            button.target = self
            button.action = #selector(togglePopover)
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

        // Discover Sonos devices with completion handler for proper initialization
        print("🔍 Starting Sonos discovery...")
        sonosController.discoverDevices { [weak self] in
            guard let self = self else { return }

            // Auto-select default speaker AFTER topology is loaded
            Task { @MainActor in
                if !self.settings.selectedSonosDevice.isEmpty {
                    print("🎵 Auto-selecting default speaker (after topology loaded): \(self.settings.selectedSonosDevice)")
                    self.sonosController.selectDevice(name: self.settings.selectedSonosDevice)
                }

                print("✅ Sonos discovery and topology loaded")
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