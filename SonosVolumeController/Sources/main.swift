import Cocoa
import CoreAudio

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var audioMonitor: AudioDeviceMonitor!
    var volumeKeyMonitor: VolumeKeyMonitor!
    var sonosController: SonosController!
    var settings: AppSettings!
    var preferencesWindow: PreferencesWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 Application did finish launching")
        // Initialize settings
        settings = AppSettings()
        print("✅ Settings initialized")

        // Initialize preferences window
        preferencesWindow = PreferencesWindow(appDelegate: self)

        // Create status bar item with "S" icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "S"
            // Make it bold and slightly larger
            button.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
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

        // Setup menu
        setupMenu()

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

    func setupMenu() {
        let menu = NSMenu()

        // Current device status
        let selectedSpeaker = settings.selectedSonosDevice.isEmpty ? "None" : settings.selectedSonosDevice
        let deviceItem = NSMenuItem(title: "Sonos: \(selectedSpeaker)", action: nil, keyEquivalent: "")
        deviceItem.isEnabled = false
        menu.addItem(deviceItem)

        menu.addItem(NSMenuItem.separator())

        // Enable/Disable
        let enableItem = NSMenuItem(
            title: "Enable Sonos Control",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        enableItem.state = settings.enabled ? .on : .off
        menu.addItem(enableItem)

        menu.addItem(NSMenuItem.separator())

        // Sonos devices submenu
        let sonosMenu = NSMenu()
        let sonosMenuItem = NSMenuItem(title: "Select Sonos Speaker", action: nil, keyEquivalent: "")
        sonosMenuItem.submenu = sonosMenu
        menu.addItem(sonosMenuItem)

        // Populate with discovered devices
        let devices = sonosController.discoveredDevices
        if devices.isEmpty {
            let noDevicesItem = NSMenuItem(title: "No devices found", action: nil, keyEquivalent: "")
            noDevicesItem.isEnabled = false
            sonosMenu.addItem(noDevicesItem)
        } else {
            for device in devices {
                let deviceItem = NSMenuItem(
                    title: device.name,
                    action: #selector(selectSonosDevice(_:)),
                    keyEquivalent: ""
                )
                deviceItem.representedObject = device.name
                // Show checkmark if this is the selected device
                if let selected = sonosController.discoveredDevices.first(where: { $0.name == settings.selectedSonosDevice }) {
                    if device.name == selected.name {
                        deviceItem.state = .on
                    }
                }
                sonosMenu.addItem(deviceItem)
            }
        }

        sonosMenu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(title: "Refresh Devices", action: #selector(refreshSonosDevices), keyEquivalent: "r")
        sonosMenu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        // Preferences
        let preferencesItem = NSMenuItem(title: "Preferences...", action: #selector(showPreferences), keyEquivalent: ",")
        menu.addItem(preferencesItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc func toggleEnabled() {
        settings.enabled.toggle()
        setupMenu()
    }

    @objc func refreshSonosDevices() {
        print("🔄 Refreshing Sonos devices...")
        sonosController.discoverDevices()
    }

    @objc func devicesDiscovered() {
        print("📱 Devices discovered, updating menu...")

        // Auto-select default speaker if set
        if !settings.selectedSonosDevice.isEmpty {
            print("🎵 Auto-selecting default speaker: \(settings.selectedSonosDevice)")
            sonosController.selectDevice(name: settings.selectedSonosDevice)
        }

        setupMenu()
    }

    @objc func selectSonosDevice(_ sender: NSMenuItem) {
        guard let deviceName = sender.representedObject as? String else { return }
        print("🎵 Selected Sonos device: \(deviceName)")
        sonosController.selectDevice(name: deviceName)
        setupMenu() // Refresh to show checkmark
    }

    @objc func showPreferences() {
        preferencesWindow.show()
    }

    @objc func quit() {
        NSApplication.shared.terminate(self)
    }
}

// Entry point - must be at the very end
print("🎬 Starting app...")
autoreleasepool {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // Menu bar app (no dock icon)
    print("📱 Activation policy set")
    let delegate = AppDelegate()
    print("👤 Delegate created")
    app.delegate = delegate
    print("🔗 Delegate assigned, running app...")
    app.run()
}