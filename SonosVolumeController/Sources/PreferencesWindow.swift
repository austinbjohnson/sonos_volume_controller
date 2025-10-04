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
    private var audioDeviceMonitor: AudioDeviceMonitor?
    private var triggerDevicePopup: NSPopUpButton?
    private var permissionStatusLabel: NSTextField?
    private var permissionIconView: NSImageView?
    private var testHotkeysButton: NSButton?
    private var hotkeyTester: HotkeyTester?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
    }

    func setAudioDeviceMonitor(_ monitor: AudioDeviceMonitor) {
        self.audioDeviceMonitor = monitor
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
        let windowRect = NSRect(x: 0, y: 0, width: 500, height: 620)
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

        // Show General tab content directly (no tabs)
        let contentView = createGeneralTab()
        window?.contentView = contentView
    }

    private func createGeneralTab() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 620))
        var yPos: CGFloat = 580

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

        yPos -= 50

        // Audio Output Trigger section header
        let triggerHeaderLabel = createLabel("Audio Output Trigger", frame: NSRect(x: 30, y: yPos, width: 200, height: 20))
        triggerHeaderLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        view.addSubview(triggerHeaderLabel)

        yPos -= 25

        // Descriptive label
        let triggerDescLabel = createLabel("Control Sonos when this device is active:", frame: NSRect(x: 30, y: yPos, width: 440, height: 20))
        triggerDescLabel.textColor = .secondaryLabelColor
        triggerDescLabel.font = NSFont.systemFont(ofSize: 11)
        view.addSubview(triggerDescLabel)

        yPos -= 30

        // Dropdown for audio device selection
        let triggerPopup = NSPopUpButton(frame: NSRect(x: 30, y: yPos, width: 350, height: 26))
        triggerPopup.bezelStyle = .rounded
        triggerPopup.target = self
        triggerPopup.action = #selector(triggerDeviceChanged(_:))
        view.addSubview(triggerPopup)
        self.triggerDevicePopup = triggerPopup

        // Populate dropdown
        populateTriggerDeviceDropdown()

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

        yPos -= 50

        // Hotkey Diagnostics section
        let diagnosticsLabel = createLabel("Hotkey Diagnostics:", frame: NSRect(x: 30, y: yPos, width: 250, height: 20))
        diagnosticsLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        view.addSubview(diagnosticsLabel)

        yPos -= 40

        // Permission status container
        let statusContainer = NSView(frame: NSRect(x: 30, y: yPos, width: 440, height: 60))
        statusContainer.wantsLayer = true
        statusContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        statusContainer.layer?.cornerRadius = 6
        view.addSubview(statusContainer)

        // Permission icon
        let icon = NSImageView(frame: NSRect(x: 12, y: 20, width: 20, height: 20))
        icon.imageScaling = .scaleProportionallyUpOrDown
        statusContainer.addSubview(icon)
        permissionIconView = icon

        // Permission status text (primary)
        let statusText = createLabel("", frame: NSRect(x: 40, y: 26, width: 350, height: 20))
        statusText.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        statusContainer.addSubview(statusText)
        permissionStatusLabel = statusText

        // Permission subtitle
        let subtitleText = createLabel("", frame: NSRect(x: 40, y: 8, width: 350, height: 16))
        subtitleText.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        subtitleText.textColor = .secondaryLabelColor
        subtitleText.tag = 1002 // For updating
        statusContainer.addSubview(subtitleText)

        // Open Settings button (shown when permission denied)
        let settingsButton = NSButton(frame: NSRect(x: 310, y: 15, width: 120, height: 28))
        settingsButton.title = "Open Settings"
        settingsButton.bezelStyle = .rounded
        settingsButton.target = self
        settingsButton.action = #selector(openAccessibilitySettings)
        settingsButton.tag = 1003 // For show/hide
        statusContainer.addSubview(settingsButton)

        yPos -= 75

        // Test Hotkeys button
        let testButton = NSButton(frame: NSRect(x: 30, y: yPos, width: 140, height: 32))
        testButton.title = "Test Hotkeys"
        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(testHotkeys(_:))
        view.addSubview(testButton)
        testHotkeysButton = testButton

        // Help text
        let helpText = createLabel(
            "Verify that your hotkeys are working correctly.",
            frame: NSRect(x: 180, y: yPos + 6, width: 290, height: 20)
        )
        helpText.textColor = .secondaryLabelColor
        helpText.font = NSFont.systemFont(ofSize: 11)
        view.addSubview(helpText)

        // Update permission status display
        updatePermissionStatus()

        // Listen for permission changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePermissionStatusChanged),
            name: NSNotification.Name("PermissionStatusChanged"),
            object: nil
        )

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
        guard let selectedTitle = sender.selectedItem?.title else { return }

        if selectedTitle == "Any Device (Always Active)" {
            appDelegate?.settings.triggerDeviceName = ""
            print("Trigger device set to: Any Device (Always Active)")
        } else {
            appDelegate?.settings.triggerDeviceName = selectedTitle
            print("Trigger device set to: \(selectedTitle)")
        }
    }

    private func populateTriggerDeviceDropdown() {
        guard let popup = triggerDevicePopup else { return }

        popup.removeAllItems()

        // Add "Any Device" as first option
        popup.addItem(withTitle: "Any Device (Always Active)")

        // Get available audio devices
        let devices = audioDeviceMonitor?.getAllAudioDevices() ?? []

        if !devices.isEmpty {
            // Add separator
            popup.menu?.addItem(NSMenuItem.separator())

            // Add each device
            for device in devices {
                popup.addItem(withTitle: device)
            }
        }

        // Select current setting
        let currentTrigger = appDelegate?.settings.triggerDeviceName ?? ""
        if currentTrigger.isEmpty {
            popup.selectItem(at: 0) // "Any Device"
        } else {
            // Try to find and select the saved device
            if let index = popup.itemTitles.firstIndex(of: currentTrigger) {
                popup.selectItem(at: index)
            } else {
                // Device not found (disconnected) - show it but grayed out
                popup.menu?.addItem(NSMenuItem.separator())
                let notFoundItem = popup.menu?.addItem(
                    withTitle: "Device Not Found: \(currentTrigger)",
                    action: nil,
                    keyEquivalent: ""
                )
                notFoundItem?.isEnabled = false

                // Select the disabled item to show user what was saved
                if let lastIndex = popup.numberOfItems - 1 as Int?, lastIndex >= 0 {
                    popup.selectItem(at: lastIndex)
                }
            }
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

    // MARK: - Permission & Testing Actions

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func handlePermissionStatusChanged() {
        updatePermissionStatus()
    }

    private func updatePermissionStatus() {
        let hasPermission = appDelegate?.settings.isAccessibilityPermissionGranted ?? false

        // Find status container to update elements
        guard let contentView = window?.contentView else { return }

        // Update icon
        if let icon = permissionIconView {
            if hasPermission {
                icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Permission Granted")
                icon.contentTintColor = .systemGreen
            } else {
                icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Permission Required")
                icon.contentTintColor = .systemOrange
            }
        }

        // Update status text
        if let statusLabel = permissionStatusLabel {
            statusLabel.stringValue = hasPermission ? "Accessibility access enabled" : "Accessibility access required"
            statusLabel.textColor = hasPermission ? .labelColor : .labelColor
        }

        // Update subtitle
        if let subtitleLabel = contentView.viewWithTag(1002) as? NSTextField {
            subtitleLabel.stringValue = hasPermission ? "Hotkeys are ready to use" : "Hotkeys won't work without this permission"
        }

        // Show/hide Open Settings button
        if let settingsButton = contentView.viewWithTag(1003) as? NSButton {
            settingsButton.isHidden = hasPermission
        }

        // Enable/disable Test button
        testHotkeysButton?.isEnabled = hasPermission
    }

    @objc private func testHotkeys(_ sender: NSButton) {
        print("🧪 Test Hotkeys button clicked")

        // Disable button during test
        sender.isEnabled = false
        sender.title = "Testing..."

        // Create tester if needed
        if hotkeyTester == nil, let monitor = appDelegate?.volumeKeyMonitor {
            hotkeyTester = HotkeyTester(volumeKeyMonitor: monitor, settings: appDelegate!.settings)
        }

        // Run test
        hotkeyTester?.testHotkeys { [weak self, weak sender] success in
            Task { @MainActor in
                // Re-enable button
                sender?.isEnabled = true
                sender?.title = "Test Hotkeys"

                // Show result modal
                self?.showTestResult(success: success)
            }
        }
    }

    private func showTestResult(success: Bool) {
        guard let window = window else { return }

        let alert = NSAlert()

        if success {
            // Success
            alert.messageText = "✅ Hotkeys Working!"
            alert.informativeText = "Volume hotkeys are working correctly.\nTry pressing F11 or F12."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Done")
        } else {
            // Failure
            alert.messageText = "❌ Hotkeys Not Working"
            alert.informativeText = "The test could not detect hotkey events.\n\nPossible issues:\n• Accessibility permission not properly granted\n• Another app is intercepting the keys\n• System settings need to be refreshed\n\nTry restarting the app or your Mac."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "Close")
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            if !success {
                if response == .alertFirstButtonReturn {
                    // Open Settings
                    self?.openAccessibilitySettings()
                } else if response == .alertSecondButtonReturn {
                    // Retry
                    self?.testHotkeys(self!.testHotkeysButton!)
                }
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Don't actually close the window, just hide it
        window?.orderOut(nil)
        return false
    }
}