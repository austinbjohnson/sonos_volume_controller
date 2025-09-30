import Cocoa

@available(macOS 26.0, *)
@MainActor
class MenuBarContentViewController: NSViewController {
    private weak var appDelegate: AppDelegate?

    // Single glass container
    private var glassView: NSGlassEffectView!

    // UI Elements
    private var statusDot: NSView!
    private var statusLabel: NSTextField!
    private var speakerNameLabel: NSTextField!
    private var volumeSlider: NSSlider!
    private var volumeLabel: NSTextField!
    private var speakerCardsContainer: NSStackView!
    private var selectedSpeakerCards: Set<String> = []
    private var groupButton: NSButton!
    private var powerButton: NSButton!

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        // Main container - wider for better layout
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 540))
        self.view = containerView

        // Single glass effect view
        glassView = NSGlassEffectView()
        glassView.cornerRadius = 24
        glassView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(glassView)

        // Main content container
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        glassView.contentView = contentView

        // Build all sections inside the single glass view
        setupHeaderSection(in: contentView)
        setupVolumeSection(in: contentView)
        setupSpeakersSection(in: contentView)
        setupActionsSection(in: contentView)

        NSLayoutConstraint.activate([
            glassView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
            glassView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            glassView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            glassView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -8)
        ])
    }

    // MARK: - Header Section (Status + Current Speaker)

    private func setupHeaderSection(in container: NSView) {
        // Status indicator dot
        statusDot = NSView()
        statusDot.wantsLayer = true
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        statusDot.layer?.cornerRadius = 5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusDot)

        // Status label
        statusLabel = NSTextField(labelWithString: "Active")
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        // Speaker name - large and prominent
        let currentSpeaker = appDelegate?.settings.selectedSonosDevice ?? "No Speaker"
        speakerNameLabel = NSTextField(labelWithString: currentSpeaker)
        speakerNameLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        speakerNameLabel.textColor = .labelColor
        speakerNameLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(speakerNameLabel)

        // Power toggle
        powerButton = NSButton()
        powerButton.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Power")
        powerButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        powerButton.bezelStyle = .inline
        powerButton.isBordered = false
        powerButton.contentTintColor = appDelegate?.settings.enabled == true ? .controlAccentColor : .tertiaryLabelColor
        powerButton.target = self
        powerButton.action = #selector(togglePower)
        powerButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(powerButton)

        // Divider
        let divider1 = createDivider()
        container.addSubview(divider1)

        NSLayoutConstraint.activate([
            // Status indicator
            statusDot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            statusDot.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),

            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: statusDot.centerYAnchor),

            // Speaker name
            speakerNameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            speakerNameLabel.topAnchor.constraint(equalTo: statusDot.bottomAnchor, constant: 10),

            // Power button
            powerButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            powerButton.centerYAnchor.constraint(equalTo: speakerNameLabel.centerYAnchor, constant: -8),
            powerButton.widthAnchor.constraint(equalToConstant: 40),
            powerButton.heightAnchor.constraint(equalToConstant: 40),

            // Divider
            divider1.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            divider1.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            divider1.topAnchor.constraint(equalTo: speakerNameLabel.bottomAnchor, constant: 20),
            divider1.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    // MARK: - Volume Section

    private func setupVolumeSection(in container: NSView) {
        // Volume icon
        let volumeIcon = NSImageView()
        volumeIcon.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Volume")
        volumeIcon.contentTintColor = .labelColor
        volumeIcon.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(volumeIcon)

        // Volume slider
        volumeSlider = NSSlider()
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 100
        volumeSlider.doubleValue = 50 // Placeholder volume
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(volumeSlider)

        // Volume percentage label
        volumeLabel = NSTextField(labelWithString: "50%")
        volumeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        volumeLabel.textColor = .labelColor
        volumeLabel.alignment = .right
        volumeLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(volumeLabel)

        // Divider
        let divider2 = createDivider()
        container.addSubview(divider2)

        // Find the previous divider to anchor to
        let previousDivider = container.subviews.compactMap { $0 as? NSBox }.first

        NSLayoutConstraint.activate([
            volumeIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            volumeIcon.topAnchor.constraint(equalTo: previousDivider!.bottomAnchor, constant: 20),
            volumeIcon.widthAnchor.constraint(equalToConstant: 22),
            volumeIcon.heightAnchor.constraint(equalToConstant: 22),

            volumeSlider.leadingAnchor.constraint(equalTo: volumeIcon.trailingAnchor, constant: 14),
            volumeSlider.centerYAnchor.constraint(equalTo: volumeIcon.centerYAnchor),
            volumeSlider.trailingAnchor.constraint(equalTo: volumeLabel.leadingAnchor, constant: -14),

            volumeLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            volumeLabel.centerYAnchor.constraint(equalTo: volumeIcon.centerYAnchor),
            volumeLabel.widthAnchor.constraint(equalToConstant: 45),

            divider2.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            divider2.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            divider2.topAnchor.constraint(equalTo: volumeIcon.bottomAnchor, constant: 20),
            divider2.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    // MARK: - Speakers Section

    private func setupSpeakersSection(in container: NSView) {
        // Section title
        let speakersTitle = NSTextField(labelWithString: "Speakers")
        speakersTitle.font = .systemFont(ofSize: 13, weight: .medium)
        speakersTitle.textColor = .secondaryLabelColor
        speakersTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(speakersTitle)

        // Scroll view for speaker cards
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false
        container.addSubview(scrollView)

        // Container for speaker cards
        speakerCardsContainer = NSStackView()
        speakerCardsContainer.orientation = .vertical
        speakerCardsContainer.spacing = 8
        speakerCardsContainer.translatesAutoresizingMaskIntoConstraints = false
        speakerCardsContainer.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)

        populateSpeakers()
        scrollView.documentView = speakerCardsContainer

        // Group button (placeholder for future functionality)
        groupButton = NSButton()
        groupButton.title = "Group Selected"
        groupButton.bezelStyle = .rounded
        groupButton.controlSize = .small
        groupButton.target = self
        groupButton.action = #selector(groupSpeakers)
        groupButton.isEnabled = false
        groupButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(groupButton)

        // Divider
        let divider3 = createDivider()
        container.addSubview(divider3)

        // Find the previous divider to anchor to
        let previousDividers = container.subviews.compactMap { $0 as? NSBox }
        let previousDivider = previousDividers[previousDividers.count - 2]

        NSLayoutConstraint.activate([
            speakersTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            speakersTitle.topAnchor.constraint(equalTo: previousDivider.bottomAnchor, constant: 16),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            scrollView.topAnchor.constraint(equalTo: speakersTitle.bottomAnchor, constant: 12),
            scrollView.heightAnchor.constraint(equalToConstant: 160),

            speakerCardsContainer.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            groupButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            groupButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),

            divider3.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            divider3.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            divider3.topAnchor.constraint(equalTo: groupButton.bottomAnchor, constant: 16),
            divider3.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    private func createSpeakerCard(device: SonosController.SonosDevice, isActive: Bool) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = isActive ?
            NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor :
            NSColor.labelColor.withAlphaComponent(0.03).cgColor
        card.layer?.cornerRadius = 10
        card.translatesAutoresizingMaskIntoConstraints = false

        // Speaker icon
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: "Speaker")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        icon.contentTintColor = isActive ? .controlAccentColor : .tertiaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        // Speaker name
        let nameLabel = NSTextField(labelWithString: device.name)
        nameLabel.font = .systemFont(ofSize: 13, weight: isActive ? .semibold : .regular)
        nameLabel.textColor = isActive ? .labelColor : .secondaryLabelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        // Selection checkbox for grouping (placeholder)
        let checkbox = NSButton()
        checkbox.setButtonType(.switch)
        checkbox.controlSize = .small
        checkbox.title = ""
        checkbox.state = selectedSpeakerCards.contains(device.name) ? .on : .off
        checkbox.target = self
        checkbox.action = #selector(speakerSelectionChanged(_:))
        checkbox.identifier = NSUserInterfaceItemIdentifier(device.name)
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        // Click gesture for main selection
        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(selectSpeaker(_:)))
        card.addGestureRecognizer(clickGesture)
        card.identifier = NSUserInterfaceItemIdentifier(device.name)

        card.addSubview(icon)
        card.addSubview(nameLabel)
        card.addSubview(checkbox)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            checkbox.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            checkbox.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            card.heightAnchor.constraint(equalToConstant: 42)
        ])

        return card
    }

    private func populateSpeakers() {
        speakerCardsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let devices = appDelegate?.sonosController.discoveredDevices else {
            let label = NSTextField(labelWithString: "No speakers found")
            label.alignment = .center
            label.textColor = .tertiaryLabelColor
            label.font = .systemFont(ofSize: 13)
            speakerCardsContainer.addArrangedSubview(label)
            return
        }

        let currentSpeaker = appDelegate?.settings.selectedSonosDevice

        for device in devices {
            let card = createSpeakerCard(device: device, isActive: device.name == currentSpeaker)
            speakerCardsContainer.addArrangedSubview(card)
        }
    }

    // MARK: - Actions Section

    private func setupActionsSection(in container: NSView) {
        // Find the last divider to anchor to
        let dividers = container.subviews.compactMap { $0 as? NSBox }
        let previousDivider = dividers.last!

        // Refresh button with label
        let refreshStack = NSStackView()
        refreshStack.orientation = .vertical
        refreshStack.spacing = 4
        refreshStack.alignment = .centerX
        refreshStack.translatesAutoresizingMaskIntoConstraints = false

        let refreshButton = NSButton()
        refreshButton.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Refresh")
        refreshButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        refreshButton.bezelStyle = .inline
        refreshButton.isBordered = false
        refreshButton.contentTintColor = .secondaryLabelColor
        refreshButton.target = self
        refreshButton.action = #selector(refreshDevices)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        let refreshLabel = NSTextField(labelWithString: "Refresh")
        refreshLabel.font = .systemFont(ofSize: 10)
        refreshLabel.textColor = .tertiaryLabelColor

        refreshStack.addArrangedSubview(refreshButton)
        refreshStack.addArrangedSubview(refreshLabel)
        container.addSubview(refreshStack)

        // Preferences button
        let prefsButton = NSButton()
        prefsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Preferences")
        prefsButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        prefsButton.bezelStyle = .inline
        prefsButton.isBordered = false
        prefsButton.contentTintColor = .secondaryLabelColor
        prefsButton.target = self
        prefsButton.action = #selector(openPreferences)
        prefsButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(prefsButton)

        // Quit button with label
        let quitStack = NSStackView()
        quitStack.orientation = .vertical
        quitStack.spacing = 4
        quitStack.alignment = .centerX
        quitStack.translatesAutoresizingMaskIntoConstraints = false

        let quitButton = NSButton()
        quitButton.image = NSImage(systemSymbolName: "power.circle", accessibilityDescription: "Quit")
        quitButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        quitButton.bezelStyle = .inline
        quitButton.isBordered = false
        quitButton.contentTintColor = .systemRed.withAlphaComponent(0.8)
        quitButton.target = self
        quitButton.action = #selector(quit)
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        let quitLabel = NSTextField(labelWithString: "Quit")
        quitLabel.font = .systemFont(ofSize: 10)
        quitLabel.textColor = .tertiaryLabelColor

        quitStack.addArrangedSubview(quitButton)
        quitStack.addArrangedSubview(quitLabel)
        container.addSubview(quitStack)

        NSLayoutConstraint.activate([
            refreshStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 50),
            refreshStack.topAnchor.constraint(equalTo: previousDivider.bottomAnchor, constant: 12),
            refreshStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),

            prefsButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            prefsButton.centerYAnchor.constraint(equalTo: refreshStack.centerYAnchor, constant: -6),
            prefsButton.widthAnchor.constraint(equalToConstant: 40),
            prefsButton.heightAnchor.constraint(equalToConstant: 40),

            quitStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -50),
            quitStack.centerYAnchor.constraint(equalTo: refreshStack.centerYAnchor),
        ])
    }

    // MARK: - Helper Methods

    private func createDivider() -> NSBox {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        return divider
    }

    // MARK: - Actions

    @objc private func togglePower() {
        let enabled = !(appDelegate?.settings.enabled ?? false)
        appDelegate?.settings.enabled = enabled
        updateStatus()
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        let volume = Int(sender.doubleValue)
        volumeLabel.stringValue = "\(volume)%"
        // Volume control is connected to the actual Sonos controller elsewhere
    }

    @objc private func selectSpeaker(_ gesture: NSClickGestureRecognizer) {
        guard let card = gesture.view,
              let deviceName = card.identifier?.rawValue else { return }

        appDelegate?.sonosController.selectDevice(name: deviceName)
        appDelegate?.settings.selectedSonosDevice = deviceName

        speakerNameLabel.stringValue = deviceName
        populateSpeakers()
    }

    @objc private func speakerSelectionChanged(_ sender: NSButton) {
        guard let deviceName = sender.identifier?.rawValue else { return }

        if sender.state == .on {
            selectedSpeakerCards.insert(deviceName)
        } else {
            selectedSpeakerCards.remove(deviceName)
        }

        groupButton.isEnabled = selectedSpeakerCards.count > 1
        groupButton.title = selectedSpeakerCards.count > 1 ?
            "Group \(selectedSpeakerCards.count) Speakers" : "Group Selected"
    }

    @objc private func groupSpeakers() {
        // Placeholder for future grouping functionality
        print("Speaker grouping will be available in a future update")
    }

    @objc private func refreshDevices() {
        appDelegate?.sonosController.discoverDevices()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.refresh()
        }
    }

    @objc private func openPreferences() {
        appDelegate?.preferencesWindow.show()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Update Methods

    private func updateStatus() {
        let enabled = appDelegate?.settings.enabled ?? false
        statusDot.layer?.backgroundColor = enabled ?
            NSColor.systemGreen.cgColor : NSColor.systemOrange.cgColor
        statusLabel.stringValue = enabled ? "Active" : "Standby"

        powerButton.contentTintColor = enabled ? .controlAccentColor : .tertiaryLabelColor
    }

    func refresh() {
        guard isViewLoaded else { return }

        speakerNameLabel.stringValue = appDelegate?.settings.selectedSonosDevice ?? "No Speaker"
        updateStatus()
        populateSpeakers()
    }
}