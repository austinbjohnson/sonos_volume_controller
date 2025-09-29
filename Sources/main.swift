import Cocoa
import CoreAudio

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var audioMonitor: AudioDeviceMonitor!
    var volumeKeyMonitor: VolumeKeyMonitor!
    var sonosController: SonosController!
    var settings: AppSettings!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize settings
        settings = AppSettings()

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "Sonos Volume Controller")
        }

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

        // Discover Sonos devices
        sonosController.discoverDevices()

        print("Sonos Volume Controller started")
    }

    func setupMenu() {
        let menu = NSMenu()

        // Current device status
        let deviceItem = NSMenuItem(title: "Current Device: \(audioMonitor.currentDeviceName)", action: nil, keyEquivalent: "")
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

        // Will be populated when devices are discovered
        let refreshItem = NSMenuItem(title: "Refresh Devices", action: #selector(refreshSonosDevices), keyEquivalent: "r")
        sonosMenu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        // Trigger device
        let triggerItem = NSMenuItem(title: "Configure Trigger Device", action: #selector(configureTriggerDevice), keyEquivalent: "")
        menu.addItem(triggerItem)

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
        sonosController.discoverDevices()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.setupMenu()
        }
    }

    @objc func configureTriggerDevice() {
        let alert = NSAlert()
        alert.messageText = "Configure Trigger Device"
        alert.informativeText = "Current trigger device: \(settings.triggerDeviceName)\n\nEnter the audio device name that should trigger Sonos control:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = settings.triggerDeviceName
        alert.accessoryView = input

        if alert.runModal() == .alertFirstButtonReturn {
            settings.triggerDeviceName = input.stringValue
        }
    }

    @objc func quit() {
        NSApplication.shared.terminate(self)
    }
}

// Run the app
NSApplication.shared.run()