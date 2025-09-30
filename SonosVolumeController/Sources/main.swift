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

        // Create status bar item with "S" icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "S"
            // Make it bold and slightly larger
            button.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
            button.target = self
            button.action = #selector(togglePopover)
            print("🔊 Menu bar icon: S")
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

        // Discover Sonos devices
        print("🔍 Starting Sonos discovery...")
        sonosController.discoverDevices()

        print("✅ Sonos Volume Controller started")
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        menuBarPopover.toggle(from: button)
    }

    @objc func devicesDiscovered() {
        print("📱 Devices discovered, updating popover...")

        // Auto-select default speaker if set
        if !settings.selectedSonosDevice.isEmpty {
            print("🎵 Auto-selecting default speaker: \(settings.selectedSonosDevice)")
            sonosController.selectDevice(name: settings.selectedSonosDevice)
        }

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