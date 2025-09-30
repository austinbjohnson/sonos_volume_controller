import Cocoa

@available(macOS 26.0, *)
@MainActor
class PreferencesWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var appDelegate: AppDelegate?
    private let keyRecorder = KeyRecorder()
    private var volumeDownTextField: NSTextField?
    private var volumeUpTextField: NSTextField?
    private var isRecordingDown = false
    private var isRecordingUp = false

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
    }

    func show() {
        // If window already exists, just show it
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create window (only once)
        createWindow()

        // Show window
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindow() {
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
        window?.delegate = self
        // Important: Release when closed to prevent leaks, but we control when it closes
        window?.isReleasedWhenClosed = false

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
        loginCheckbox.state = LoginItemManager.shared.isEnabled ? .on : .off
        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLoginItem(_:))
        view.addSubview(loginCheckbox)

        yPos -= 60

        // Volume Step label
        let volumeLabel = createLabel("Volume Step Size:", frame: NSRect(x: 30, y: yPos, width: 200, height: 20))
        view.addSubview(volumeLabel)

        yPos -= 35

        // Volume Step slider
        let volumeSlider = NSSlider(frame: NSRect(x: 30, y: yPos, width: 350, height: 25))
        volumeSlider.minValue = 1
        volumeSlider.maxValue = 20
        volumeSlider.intValue = Int32(appDelegate?.settings.volumeStep ?? 5)
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeStepChanged(_:))
        view.addSubview(volumeSlider)

        // Volume step value label
        let currentStep = appDelegate?.settings.volumeStep ?? 5
        let volumeValueLabel = createLabel("\(currentStep)%", frame: NSRect(x: 390, y: yPos + 2, width: 60, height: 20))
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

        let downKeyCode = appDelegate?.settings.volumeDownKeyCode ?? 103
        let downModifiers = appDelegate?.settings.volumeDownModifiers ?? 0
        let downKeyCombo = appDelegate?.settings.keyComboName(for: downKeyCode, modifiers: downModifiers) ?? "F11"
        let downText = createTextField(downKeyCombo, frame: NSRect(x: 140, y: yPos, width: 150, height: 24))
        downText.alignment = .center
        view.addSubview(downText)
        volumeDownTextField = downText

        let downButton = NSButton(frame: NSRect(x: 300, y: yPos - 2, width: 100, height: 28))
        downButton.title = "Record"
        downButton.bezelStyle = .rounded
        downButton.target = self
        downButton.action = #selector(recordVolumeDownKey(_:))
        view.addSubview(downButton)

        yPos -= 45

        // Volume Up hotkey
        let upLabel = createLabel("Volume Up:", frame: NSRect(x: 30, y: yPos + 4, width: 110, height: 20))
        view.addSubview(upLabel)

        let upKeyCode = appDelegate?.settings.volumeUpKeyCode ?? 111
        let upModifiers = appDelegate?.settings.volumeUpModifiers ?? 0
        let upKeyCombo = appDelegate?.settings.keyComboName(for: upKeyCode, modifiers: upModifiers) ?? "F12"
        let upText = createTextField(upKeyCombo, frame: NSRect(x: 140, y: yPos, width: 150, height: 24))
        upText.alignment = .center
        view.addSubview(upText)
        volumeUpTextField = upText

        let upButton = NSButton(frame: NSRect(x: 300, y: yPos - 2, width: 100, height: 28))
        upButton.title = "Record"
        upButton.bezelStyle = .rounded
        upButton.target = self
        upButton.action = #selector(recordVolumeUpKey(_:))
        view.addSubview(upButton)

        yPos -= 50

        // Info label
        let infoLabel = createLabel(
            "Click 'Record' and press any key to set a custom hotkey.",
            frame: NSRect(x: 30, y: yPos, width: 500, height: 20)
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

        do {
            try LoginItemManager.shared.setEnabled(enabled)
            let status = LoginItemManager.shared.statusDescription
            print("✅ Login item \(enabled ? "enabled" : "disabled"): \(status)")

            // If requires approval, show alert
            if status.contains("approval") {
                let alert = NSAlert()
                alert.messageText = "Approval Required"
                alert.informativeText = "Please approve Sonos Volume Controller in System Settings > General > Login Items & Extensions"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        } catch {
            print("❌ Failed to \(enabled ? "enable" : "disable") login item: \(error)")
            sender.state = enabled ? .off : .on  // Revert checkbox

            let alert = NSAlert()
            alert.messageText = "Failed to Update Login Item"
            alert.informativeText = "Error: \(error.localizedDescription)\n\nNote: This feature requires building as a .app bundle. Run './build-app.sh' to create SonosVolumeController.app"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func volumeStepChanged(_ sender: NSSlider) {
        let value = sender.intValue
        // Update label
        if let view = sender.superview,
           let label = view.viewWithTag(1001) as? NSTextField {
            label.stringValue = "\(value)%"
        }
        // Save to settings
        appDelegate?.settings.volumeStep = Int(value)
        print("Volume step changed to: \(value)%")
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
        print("Refreshing Sonos devices and topology...")
        appDelegate?.sonosController.discoverDevices(forceRefreshTopology: true)

        // Refresh UI after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            // For now, just show a message that devices were refreshed
            // In a proper implementation, we'd update the dropdown in place
            print("Sonos devices and topology refreshed - please reopen preferences to see updates")
        }
    }

    @objc private func recordVolumeDownKey(_ sender: NSButton) {
        guard !isRecordingDown else { return }

        isRecordingDown = true
        sender.title = "Listening..."
        volumeDownTextField?.stringValue = "Press a key..."

        keyRecorder.startRecording { [weak self] keyCode, modifiers in
            guard let self = self else { return }

            self.isRecordingDown = false
            sender.title = "Record"

            // Update settings
            self.appDelegate?.settings.volumeDownKeyCode = keyCode
            self.appDelegate?.settings.volumeDownModifiers = modifiers

            // Update display
            let keyCombo = self.appDelegate?.settings.keyComboName(for: keyCode, modifiers: modifiers) ?? "Key \(keyCode)"
            self.volumeDownTextField?.stringValue = keyCombo

            print("✅ Volume down key set to: \(keyCombo) (code: \(keyCode), modifiers: \(modifiers))")
        }
    }

    @objc private func recordVolumeUpKey(_ sender: NSButton) {
        guard !isRecordingUp else { return }

        isRecordingUp = true
        sender.title = "Listening..."
        volumeUpTextField?.stringValue = "Press a key..."

        keyRecorder.startRecording { [weak self] keyCode, modifiers in
            guard let self = self else { return }

            self.isRecordingUp = false
            sender.title = "Record"

            // Update settings
            self.appDelegate?.settings.volumeUpKeyCode = keyCode
            self.appDelegate?.settings.volumeUpModifiers = modifiers

            // Update display
            let keyCombo = self.appDelegate?.settings.keyComboName(for: keyCode, modifiers: modifiers) ?? "Key \(keyCode)"
            self.volumeUpTextField?.stringValue = keyCombo

            print("✅ Volume up key set to: \(keyCombo) (code: \(keyCode), modifiers: \(modifiers))")
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Don't actually close the window, just hide it
        window?.orderOut(nil)
        return false
    }
}