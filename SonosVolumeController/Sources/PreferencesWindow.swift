import Cocoa

@MainActor
class PreferencesWindow: NSObject {
    private var window: NSWindow?
    private weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
    }

    func show() {
        // If window already exists, just show it
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create window
        let windowRect = NSRect(x: 0, y: 0, width: 600, height: 500)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]

        window = NSWindow(
            contentRect: windowRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        window?.title = "Preferences"
        window?.center()

        // Create tab view
        let tabView = NSTabView(frame: NSRect(x: 20, y: 20, width: 560, height: 430))

        // General Tab
        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "General"
        generalTab.view = createGeneralTab()
        tabView.addTabViewItem(generalTab)

        // Audio Devices Tab
        let audioTab = NSTabViewItem(identifier: "audio")
        audioTab.label = "Audio Devices"
        audioTab.view = createAudioTab()
        tabView.addTabViewItem(audioTab)

        // Sonos Tab
        let sonosTab = NSTabViewItem(identifier: "sonos")
        sonosTab.label = "Sonos"
        sonosTab.view = createSonosTab()
        tabView.addTabViewItem(sonosTab)

        window?.contentView?.addSubview(tabView)

        // Show window
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createGeneralTab() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))
        var yPos: CGFloat = 360

        // Enable/Disable checkbox
        let enableCheckbox = NSButton(frame: NSRect(x: 30, y: yPos, width: 300, height: 25))
        enableCheckbox.setButtonType(.switch)
        enableCheckbox.title = "Enable Sonos Control"
        enableCheckbox.state = appDelegate?.settings.enabled == true ? .on : .off
        enableCheckbox.target = self
        enableCheckbox.action = #selector(toggleEnabled(_:))
        view.addSubview(enableCheckbox)

        yPos -= 40

        // Run at Login checkbox
        let loginCheckbox = NSButton(frame: NSRect(x: 30, y: yPos, width: 300, height: 25))
        loginCheckbox.setButtonType(.switch)
        loginCheckbox.title = "Run at Login"
        loginCheckbox.state = .off  // TODO: Check actual login item status
        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLoginItem(_:))
        view.addSubview(loginCheckbox)

        yPos -= 60

        // Volume Step label
        let volumeLabel = createLabel("Volume Step Size:", frame: NSRect(x: 30, y: yPos, width: 200, height: 20))
        view.addSubview(volumeLabel)

        yPos -= 35

        // Volume Step slider (currently hardcoded to 5 in SonosController)
        let volumeSlider = NSSlider(frame: NSRect(x: 30, y: yPos, width: 350, height: 25))
        volumeSlider.minValue = 1
        volumeSlider.maxValue = 20
        volumeSlider.intValue = 5  // TODO: Make this configurable
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeStepChanged(_:))
        view.addSubview(volumeSlider)

        // Volume step value label
        let volumeValueLabel = createLabel("5%", frame: NSRect(x: 390, y: yPos + 2, width: 60, height: 20))
        volumeValueLabel.tag = 1001 // For updating later
        view.addSubview(volumeValueLabel)

        yPos -= 60

        // Hotkey section header
        let hotkeyLabel = createLabel("Volume Control Hotkeys:", frame: NSRect(x: 30, y: yPos, width: 250, height: 20))
        view.addSubview(hotkeyLabel)

        yPos -= 40

        // Volume Down hotkey
        let downLabel = createLabel("Volume Down:", frame: NSRect(x: 30, y: yPos + 4, width: 110, height: 20))
        view.addSubview(downLabel)

        let downText = createTextField("F11", frame: NSRect(x: 140, y: yPos, width: 150, height: 24))
        downText.alignment = .center
        view.addSubview(downText)

        let downButton = NSButton(frame: NSRect(x: 300, y: yPos - 2, width: 100, height: 28))
        downButton.title = "Record"
        downButton.bezelStyle = .rounded
        view.addSubview(downButton)

        yPos -= 45

        // Volume Up hotkey
        let upLabel = createLabel("Volume Up:", frame: NSRect(x: 30, y: yPos + 4, width: 110, height: 20))
        view.addSubview(upLabel)

        let upText = createTextField("F12", frame: NSRect(x: 140, y: yPos, width: 150, height: 24))
        upText.alignment = .center
        view.addSubview(upText)

        let upButton = NSButton(frame: NSRect(x: 300, y: yPos - 2, width: 100, height: 28))
        upButton.title = "Record"
        upButton.bezelStyle = .rounded
        view.addSubview(upButton)

        yPos -= 50

        // Info label
        let infoLabel = createLabel(
            "Hotkeys are currently hardcoded to F11 (down) / F12 (up).\nCustomizable hotkeys coming in future update.",
            frame: NSRect(x: 30, y: yPos, width: 500, height: 40)
        )
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = NSFont.systemFont(ofSize: 11)
        view.addSubview(infoLabel)

        return view
    }

    private func createAudioTab() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))
        var yPos: CGFloat = 360

        // Trigger Device label
        let triggerLabel = createLabel(
            "Trigger Audio Device (activates Sonos control):",
            frame: NSRect(x: 30, y: yPos, width: 500, height: 20)
        )
        view.addSubview(triggerLabel)

        yPos -= 35

        // Audio device dropdown
        let audioDropdown = NSPopUpButton(frame: NSRect(x: 30, y: yPos, width: 450, height: 26), pullsDown: false)
        audioDropdown.removeAllItems()
        audioDropdown.autoenablesItems = false

        // Populate with all audio devices
        if let devices = appDelegate?.audioMonitor.getAllAudioDevices() {
            for device in devices {
                audioDropdown.addItem(withTitle: device)
            }
        }

        // Select current trigger device
        if let triggerDevice = appDelegate?.settings.triggerDeviceName,
           !triggerDevice.isEmpty {
            audioDropdown.selectItem(withTitle: triggerDevice)
        }

        audioDropdown.target = self
        audioDropdown.action = #selector(triggerDeviceChanged(_:))
        view.addSubview(audioDropdown)

        yPos -= 60

        // Current device label
        let currentDevice = appDelegate?.audioMonitor.currentDeviceName ?? "Unknown"
        let currentLabel = createLabel(
            "Current Active Device: \(currentDevice)",
            frame: NSRect(x: 30, y: yPos, width: 500, height: 20)
        )
        view.addSubview(currentLabel)

        yPos -= 35

        // Status indicator
        let isActive = appDelegate?.audioMonitor.shouldInterceptVolumeKeys == true
        let statusText = isActive ? "✅ Active (Sonos control enabled)" : "⚪ Inactive (using different device)"
        let statusLabel = createLabel(statusText, frame: NSRect(x: 30, y: yPos, width: 500, height: 20))
        view.addSubview(statusLabel)

        return view
    }

    private func createSonosTab() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))
        var yPos: CGFloat = 360

        // Default speaker label
        let defaultLabel = createLabel(
            "Default Sonos Speaker (auto-select on startup):",
            frame: NSRect(x: 30, y: yPos, width: 500, height: 20)
        )
        view.addSubview(defaultLabel)

        yPos -= 35

        // Sonos speaker dropdown
        let sonosDropdown = NSPopUpButton(frame: NSRect(x: 30, y: yPos, width: 450, height: 26), pullsDown: false)
        sonosDropdown.removeAllItems()
        sonosDropdown.autoenablesItems = false

        sonosDropdown.addItem(withTitle: "(None - Manual Selection)")

        if let devices = appDelegate?.sonosController.discoveredDevices {
            for device in devices {
                sonosDropdown.addItem(withTitle: device.name)
            }
        }

        // Select current default speaker
        if let defaultSpeaker = appDelegate?.settings.selectedSonosDevice,
           !defaultSpeaker.isEmpty {
            sonosDropdown.selectItem(withTitle: defaultSpeaker)
        }

        sonosDropdown.target = self
        sonosDropdown.action = #selector(defaultSpeakerChanged(_:))
        view.addSubview(sonosDropdown)

        yPos -= 50

        // Refresh button
        let refreshButton = NSButton(frame: NSRect(x: 30, y: yPos, width: 150, height: 28))
        refreshButton.title = "Refresh Devices"
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshSonos(_:))
        view.addSubview(refreshButton)

        yPos -= 60

        // Current speaker
        let currentSpeaker = appDelegate?.settings.selectedSonosDevice ?? "(None)"
        let currentSpeakerLabel = createLabel(
            "Currently Controlling: \(currentSpeaker)",
            frame: NSRect(x: 30, y: yPos, width: 500, height: 20)
        )
        view.addSubview(currentSpeakerLabel)

        yPos -= 35

        // Device count
        let deviceCount = appDelegate?.sonosController.discoveredDevices.count ?? 0
        let deviceCountLabel = createLabel(
            "Discovered Devices: \(deviceCount)",
            frame: NSRect(x: 30, y: yPos, width: 500, height: 20)
        )
        view.addSubview(deviceCountLabel)

        return view
    }

    // MARK: - Helper Methods

    private func createLabel(_ text: String, frame: NSRect) -> NSTextField {
        let label = NSTextField(frame: frame)
        label.stringValue = text
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        return label
    }

    private func createTextField(_ text: String, frame: NSRect) -> NSTextField {
        let textField = NSTextField(frame: frame)
        textField.stringValue = text
        textField.isBezeled = true
        textField.drawsBackground = true
        textField.isEditable = false
        textField.isSelectable = false
        return textField
    }

    // MARK: - Actions

    @objc private func toggleEnabled(_ sender: NSButton) {
        appDelegate?.settings.enabled = sender.state == .on
        print("Sonos control \(sender.state == .on ? "enabled" : "disabled")")
    }

    @objc private func toggleLoginItem(_ sender: NSButton) {
        let enabled = sender.state == .on

        if enabled {
            // Add to login items
            // TODO: Implement using SMAppService or LSSharedFileList
            print("⚠️ Run at login: Not yet implemented (needs .app bundle)")
            print("   This feature requires building as .app with proper bundle identifier")
            sender.state = .off  // Revert for now
        } else {
            print("Removed from login items")
        }
    }

    @objc private func volumeStepChanged(_ sender: NSSlider) {
        let value = sender.intValue
        // Update label
        if let view = sender.superview,
           let label = view.viewWithTag(1001) as? NSTextField {
            label.stringValue = "\(value)%"
        }
        print("Volume step changed to: \(value)%")
        // TODO: Store in settings and update SonosController
    }

    @objc private func triggerDeviceChanged(_ sender: NSPopUpButton) {
        guard let selectedDevice = sender.selectedItem?.title else { return }
        appDelegate?.settings.triggerDeviceName = selectedDevice
        print("Trigger device set to: \(selectedDevice)")
    }

    @objc private func defaultSpeakerChanged(_ sender: NSPopUpButton) {
        guard let selectedTitle = sender.selectedItem?.title else { return }

        if selectedTitle == "(None - Manual Selection)" {
            appDelegate?.settings.selectedSonosDevice = ""
            print("Default speaker cleared")
        } else {
            appDelegate?.settings.selectedSonosDevice = selectedTitle
            appDelegate?.sonosController.selectDevice(name: selectedTitle)
            print("Default speaker set to: \(selectedTitle)")
        }
    }

    @objc private func refreshSonos(_ sender: NSButton) {
        print("Refreshing Sonos devices...")
        appDelegate?.sonosController.discoverDevices()

        // Close and reopen window to refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.window?.close()
            self.window = nil
            self.show()
        }
    }
}