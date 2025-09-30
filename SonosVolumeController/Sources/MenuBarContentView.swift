import Cocoa

@available(macOS 26.0, *)
@MainActor
class MenuBarContentViewController: NSViewController, NSGestureRecognizerDelegate {
    private weak var appDelegate: AppDelegate?

    // Single glass container
    private var glassView: NSGlassEffectView!

    // UI Elements
    private var statusDot: NSView!
    private var statusLabel: NSTextField!
    private var speakerNameLabel: NSTextField!
    private var volumeSlider: NSSlider!
    private var volumeLabel: NSTextField!
    private var volumeTypeLabel: NSTextField!  // "Group Volume" or "Speaker Volume"
    private var speakerCardsContainer: NSStackView!
    private var selectedSpeakerCards: Set<String> = []
    private var groupButton: NSButton!
    private var powerButton: NSButton!
    private var isLoadingDevices: Bool = false
    private var welcomeBanner: NSView!

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        // Main container - wider and taller to fit all speakers
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 650))
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
        setupTriggerDeviceSection(in: contentView)
        setupActionsSection(in: contentView)

        NSLayoutConstraint.activate([
            glassView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
            glassView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            glassView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            glassView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -8)
        ])

        // Observe volume changes to update slider in real-time
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(volumeDidChange(_:)),
            name: NSNotification.Name("SonosVolumeDidChange"),
            object: nil
        )

        // Observe device discovery events
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(discoveryStarted),
            name: NSNotification.Name("SonosDiscoveryStarted"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(devicesDiscovered),
            name: NSNotification.Name("SonosDevicesDiscovered"),
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        // Volume type label (Group Volume or Speaker Volume)
        volumeTypeLabel = NSTextField(labelWithString: "Volume")
        volumeTypeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        volumeTypeLabel.textColor = .secondaryLabelColor
        volumeTypeLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(volumeTypeLabel)

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
        volumeSlider.doubleValue = 0
        volumeSlider.isEnabled = false // Disabled until volume is loaded
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(volumeSlider)

        // Volume will be fetched after device discovery completes (via notification)
        // Don't fetch here as it would return default 50 before discovery finishes

        // Volume percentage label
        volumeLabel = NSTextField(labelWithString: "—")
        volumeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        volumeLabel.textColor = .secondaryLabelColor
        volumeLabel.alignment = .right
        volumeLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(volumeLabel)

        // Divider
        let divider2 = createDivider()
        container.addSubview(divider2)

        // Find the previous divider to anchor to
        let previousDivider = container.subviews.compactMap { $0 as? NSBox }.first

        NSLayoutConstraint.activate([
            volumeTypeLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            volumeTypeLabel.topAnchor.constraint(equalTo: previousDivider!.bottomAnchor, constant: 16),

            volumeIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            volumeIcon.topAnchor.constraint(equalTo: volumeTypeLabel.bottomAnchor, constant: 8),
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
            divider2.topAnchor.constraint(equalTo: volumeIcon.bottomAnchor, constant: 16),
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

        // Welcome banner for first launch
        welcomeBanner = createWelcomeBanner()
        container.addSubview(welcomeBanner)

        // Scroll view for speaker cards
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.automaticallyAdjustsContentInsets = false
        container.addSubview(scrollView)

        // Container for speaker cards
        speakerCardsContainer = NSStackView()
        speakerCardsContainer.orientation = .vertical
        speakerCardsContainer.spacing = 8
        speakerCardsContainer.translatesAutoresizingMaskIntoConstraints = false
        speakerCardsContainer.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)

        // Show loading indicator if no devices discovered yet
        if appDelegate?.sonosController.discoveredDevices.isEmpty != false {
            isLoadingDevices = true
        }

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
            speakersTitle.topAnchor.constraint(equalTo: previousDivider.bottomAnchor, constant: 12),

            welcomeBanner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            welcomeBanner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            welcomeBanner.topAnchor.constraint(equalTo: speakersTitle.bottomAnchor, constant: 12),
            welcomeBanner.heightAnchor.constraint(equalToConstant: 50),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            scrollView.topAnchor.constraint(equalTo: welcomeBanner.bottomAnchor, constant: 8),
            scrollView.heightAnchor.constraint(equalToConstant: 250),

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
        // Check if device is in a multi-speaker group
        let isInGroup = device.groupCoordinatorUUID != nil &&
                       appDelegate?.sonosController.discoveredGroups.first(where: {
                           $0.coordinatorUUID == device.groupCoordinatorUUID && $0.members.count > 1
                       }) != nil
        let isGroupCoordinator = device.isGroupCoordinator && isInGroup

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = isActive ?
            NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor :
            NSColor.labelColor.withAlphaComponent(0.03).cgColor
        card.layer?.cornerRadius = 10
        card.translatesAutoresizingMaskIntoConstraints = false

        // Add left border for grouped (non-coordinator) devices
        if isInGroup && !isGroupCoordinator {
            let groupIndicator = NSView()
            groupIndicator.wantsLayer = true
            groupIndicator.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
            groupIndicator.layer?.cornerRadius = 1.5
            groupIndicator.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(groupIndicator)

            NSLayoutConstraint.activate([
                groupIndicator.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4),
                groupIndicator.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
                groupIndicator.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
                groupIndicator.widthAnchor.constraint(equalToConstant: 3)
            ])
        }

        // Speaker icon
        let icon = NSImageView()
        let iconName = isGroupCoordinator ? "person.3.fill" : "hifispeaker.fill"
        icon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Speaker")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        icon.contentTintColor = isGroupCoordinator ? .systemBlue : (isActive ? .controlAccentColor : .tertiaryLabelColor)
        icon.translatesAutoresizingMaskIntoConstraints = false

        // Build display name with group info
        var displayName = device.name
        if isActive {
            displayName += " (Default)"
        }

        // Create a stack for name + group info
        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.spacing = 2
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: displayName)
        nameLabel.font = .systemFont(ofSize: 13, weight: isActive ? .semibold : .regular)
        nameLabel.textColor = isActive ? .labelColor : .secondaryLabelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(nameLabel)

        // Add group info label if in a group
        if isInGroup {
            let group = appDelegate?.sonosController.discoveredGroups.first(where: {
                $0.coordinatorUUID == device.groupCoordinatorUUID
            })
            if let group = group {
                let groupInfoText: String
                if isGroupCoordinator {
                    let memberCount = group.members.count - 1
                    groupInfoText = memberCount == 1 ? "Group leader + 1 speaker" : "Group leader + \(memberCount) speakers"
                } else {
                    groupInfoText = "Grouped with \(group.coordinator.name)"
                }

                let groupLabel = NSTextField(labelWithString: groupInfoText)
                groupLabel.font = .systemFont(ofSize: 10, weight: .regular)
                groupLabel.textColor = .systemBlue
                groupLabel.translatesAutoresizingMaskIntoConstraints = false
                textStack.addArrangedSubview(groupLabel)
            }
        }

        // Selection checkbox for grouping
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
        clickGesture.delaysPrimaryMouseButtonEvents = false // Don't delay button clicks
        clickGesture.delegate = self
        card.addGestureRecognizer(clickGesture)
        card.identifier = NSUserInterfaceItemIdentifier(device.name)

        let leadingOffset: CGFloat = (isInGroup && !isGroupCoordinator) ? 20 : 12

        card.addSubview(icon)
        card.addSubview(textStack)
        card.addSubview(checkbox)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: leadingOffset),
            icon.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            textStack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: checkbox.leadingAnchor, constant: -8),

            checkbox.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            checkbox.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 50)
        ])

        return card
    }

    private func populateSpeakers() {
        speakerCardsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Show loading indicator if discovery is in progress
        if isLoadingDevices {
            let loadingStack = NSStackView()
            loadingStack.orientation = .vertical
            loadingStack.spacing = 12
            loadingStack.alignment = .centerX

            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .regular
            spinner.startAnimation(nil)

            let loadingLabel = NSTextField(labelWithString: "Discovering speakers...")
            loadingLabel.alignment = .center
            loadingLabel.textColor = .secondaryLabelColor
            loadingLabel.font = .systemFont(ofSize: 13)

            loadingStack.addArrangedSubview(spinner)
            loadingStack.addArrangedSubview(loadingLabel)

            speakerCardsContainer.addArrangedSubview(loadingStack)
            return
        }

        guard let devices = appDelegate?.sonosController.discoveredDevices, !devices.isEmpty else {
            let label = NSTextField(labelWithString: "No speakers found")
            label.alignment = .center
            label.textColor = .tertiaryLabelColor
            label.font = .systemFont(ofSize: 13)
            speakerCardsContainer.addArrangedSubview(label)
            return
        }

        let currentSpeaker = appDelegate?.settings.selectedSonosDevice

        // Show/hide welcome banner based on whether a speaker is selected
        if let banner = welcomeBanner {
            banner.isHidden = !(currentSpeaker?.isEmpty ?? true)
        }

        // Sort devices: default speaker first, then group by coordinator, then alphabetically
        let sortedDevices = devices.sorted { device1, device2 in
            let isDevice1Current = device1.name == currentSpeaker
            let isDevice2Current = device2.name == currentSpeaker

            // Default speaker always first
            if isDevice1Current && !isDevice2Current {
                return true
            } else if !isDevice1Current && isDevice2Current {
                return false
            }

            // Group coordinators before their members
            let coord1 = device1.groupCoordinatorUUID ?? device1.uuid
            let coord2 = device2.groupCoordinatorUUID ?? device2.uuid

            if coord1 == coord2 {
                // Same group - coordinator first, then members alphabetically
                if device1.isGroupCoordinator && !device2.isGroupCoordinator {
                    return true
                } else if !device1.isGroupCoordinator && device2.isGroupCoordinator {
                    return false
                } else {
                    return device1.name.localizedCaseInsensitiveCompare(device2.name) == .orderedAscending
                }
            } else {
                // Different groups - sort by coordinator name
                let coord1Name = devices.first { $0.uuid == coord1 }?.name ?? ""
                let coord2Name = devices.first { $0.uuid == coord2 }?.name ?? ""
                return coord1Name.localizedCaseInsensitiveCompare(coord2Name) == .orderedAscending
            }
        }

        for device in sortedDevices {
            let isActive = device.name == currentSpeaker
            let card = createSpeakerCard(device: device, isActive: isActive)
            speakerCardsContainer.addArrangedSubview(card)
        }
    }

    // MARK: - Trigger Device Section

    private func setupTriggerDeviceSection(in container: NSView) {
        // Section title
        let triggerTitle = NSTextField(labelWithString: "Audio Trigger")
        triggerTitle.font = .systemFont(ofSize: 13, weight: .medium)
        triggerTitle.textColor = .secondaryLabelColor
        triggerTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(triggerTitle)

        // Description
        let description = NSTextField(wrappingLabelWithString: "Hotkeys work when this device is active:")
        description.font = .systemFont(ofSize: 11, weight: .regular)
        description.textColor = .tertiaryLabelColor
        description.maximumNumberOfLines = 2
        description.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(description)

        // Radio buttons container
        let radioContainer = NSStackView()
        radioContainer.orientation = .vertical
        radioContainer.spacing = 8
        radioContainer.alignment = .leading
        radioContainer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(radioContainer)

        // Get current trigger device setting
        guard let settings = appDelegate?.settings else { return }
        let currentTrigger = settings.triggerDeviceName

        // "Any Device" option (recommended)
        let anyDeviceButton = NSButton()
        anyDeviceButton.setButtonType(.radio)
        anyDeviceButton.title = "Any Device (recommended)"
        anyDeviceButton.font = .systemFont(ofSize: 12, weight: .regular)
        anyDeviceButton.state = currentTrigger.isEmpty ? .on : .off
        anyDeviceButton.target = self
        anyDeviceButton.action = #selector(triggerDeviceChanged(_:))
        anyDeviceButton.identifier = NSUserInterfaceItemIdentifier("")  // Empty = any device
        radioContainer.addArrangedSubview(anyDeviceButton)

        // Get all audio devices
        guard let audioMonitor = appDelegate?.audioMonitor else { return }
        let audioDevices = audioMonitor.getAllAudioDevices()

        // Create radio button for each audio device
        for device in audioDevices {
            let deviceButton = NSButton()
            deviceButton.setButtonType(.radio)
            deviceButton.title = device
            deviceButton.font = .systemFont(ofSize: 12, weight: .regular)
            deviceButton.state = (device == currentTrigger) ? .on : .off
            deviceButton.target = self
            deviceButton.action = #selector(triggerDeviceChanged(_:))
            deviceButton.identifier = NSUserInterfaceItemIdentifier(device)
            radioContainer.addArrangedSubview(deviceButton)
        }

        // Divider
        let divider4 = createDivider()
        container.addSubview(divider4)

        // Find the previous divider to anchor to
        let previousDividers = container.subviews.compactMap { $0 as? NSBox }
        let previousDivider = previousDividers[previousDividers.count - 2]

        NSLayoutConstraint.activate([
            triggerTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            triggerTitle.topAnchor.constraint(equalTo: previousDivider.bottomAnchor, constant: 12),

            description.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            description.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            description.topAnchor.constraint(equalTo: triggerTitle.bottomAnchor, constant: 4),

            radioContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            radioContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            radioContainer.topAnchor.constraint(equalTo: description.bottomAnchor, constant: 8),

            divider4.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            divider4.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            divider4.topAnchor.constraint(equalTo: radioContainer.bottomAnchor, constant: 16),
            divider4.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    @objc private func triggerDeviceChanged(_ sender: NSButton) {
        guard let settings = appDelegate?.settings else { return }
        let deviceName = sender.identifier?.rawValue ?? ""
        settings.triggerDeviceName = deviceName
        print("Trigger device changed to: \(deviceName.isEmpty ? "Any Device" : deviceName)")
    }

    // MARK: - Actions Section

    private func setupActionsSection(in container: NSView) {
        // Find the last divider to anchor to
        let dividers = container.subviews.compactMap { $0 as? NSBox }
        let previousDivider = dividers.last!

        // Preferences button with label
        let prefsStack = NSStackView()
        prefsStack.orientation = .vertical
        prefsStack.spacing = 4
        prefsStack.alignment = .centerX
        prefsStack.translatesAutoresizingMaskIntoConstraints = false

        let prefsButton = NSButton()
        prefsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Preferences")
        prefsButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        prefsButton.bezelStyle = .inline
        prefsButton.isBordered = false
        prefsButton.contentTintColor = .secondaryLabelColor
        prefsButton.target = self
        prefsButton.action = #selector(openPreferences)
        prefsButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            prefsButton.widthAnchor.constraint(equalToConstant: 44),
            prefsButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        prefsStack.addArrangedSubview(prefsButton)
        container.addSubview(prefsStack)

        // Quit button with label
        let quitStack = NSStackView()
        quitStack.orientation = .vertical
        quitStack.spacing = 4
        quitStack.alignment = .centerX
        quitStack.translatesAutoresizingMaskIntoConstraints = false

        let quitButton = NSButton()
        quitButton.image = NSImage(systemSymbolName: "figure.walk.departure", accessibilityDescription: "Quit")
        quitButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        quitButton.bezelStyle = .inline
        quitButton.isBordered = false
        quitButton.contentTintColor = .secondaryLabelColor
        quitButton.target = self
        quitButton.action = #selector(quit)
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            quitButton.widthAnchor.constraint(equalToConstant: 44),
            quitButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        quitStack.addArrangedSubview(quitButton)
        container.addSubview(quitStack)

        NSLayoutConstraint.activate([
            prefsStack.trailingAnchor.constraint(equalTo: container.centerXAnchor, constant: -40),
            prefsStack.topAnchor.constraint(equalTo: previousDivider.bottomAnchor, constant: 16),
            prefsStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),

            quitStack.leadingAnchor.constraint(equalTo: container.centerXAnchor, constant: 40),
            quitStack.topAnchor.constraint(equalTo: previousDivider.bottomAnchor, constant: 16),
        ])
    }

    // MARK: - Helper Methods

    private func createDivider() -> NSBox {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        return divider
    }

    private func createWelcomeBanner() -> NSView {
        let banner = NSView()
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
        banner.layer?.cornerRadius = 8
        banner.translatesAutoresizingMaskIntoConstraints = false

        // Welcome icon
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "hand.wave.fill", accessibilityDescription: "Welcome")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        // Welcome text
        let text = NSTextField(labelWithString: "Welcome! Select your default speaker below to get started.")
        text.font = .systemFont(ofSize: 12, weight: .medium)
        text.textColor = .labelColor
        text.alignment = .left
        text.translatesAutoresizingMaskIntoConstraints = false

        banner.addSubview(icon)
        banner.addSubview(text)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
            text.centerYAnchor.constraint(equalTo: banner.centerYAnchor)
        ])

        // Initially hidden - will be shown only when no speaker is selected
        banner.isHidden = true

        return banner
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
        volumeLabel.textColor = .labelColor
        // Set the actual Sonos volume
        appDelegate?.sonosController.setVolume(volume)
    }

    @objc private func volumeDidChange(_ notification: Notification) {
        // Update slider when volume changes via hotkeys or initial load
        guard let userInfo = notification.userInfo,
              let volume = userInfo["volume"] as? Int else { return }

        volumeSlider.doubleValue = Double(volume)
        volumeLabel.stringValue = "\(volume)%"
        volumeLabel.textColor = .labelColor

        // Enable slider now that we have actual volume
        if !volumeSlider.isEnabled {
            volumeSlider.isEnabled = true
        }
    }

    @objc private func discoveryStarted() {
        // Discovery started, show loading indicator
        isLoadingDevices = true
        populateSpeakers()
    }

    @objc private func devicesDiscovered() {
        // Discovery completed, hide loading indicator
        isLoadingDevices = false
        populateSpeakers()
    }

    // NSGestureRecognizerDelegate - prevent gesture from starting if clicking on checkbox
    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard let clickGesture = gestureRecognizer as? NSClickGestureRecognizer,
              let card = clickGesture.view else { return true }

        // Check if click location is on a button (checkbox)
        let clickLocation = clickGesture.location(in: card)
        for subview in card.subviews {
            if subview is NSButton && subview.frame.contains(clickLocation) {
                // Don't start gesture - let the button handle it
                return false
            }
        }
        return true
    }

    @objc private func selectSpeaker(_ gesture: NSClickGestureRecognizer) {
        guard let card = gesture.view,
              let deviceName = card.identifier?.rawValue else { return }

        appDelegate?.sonosController.selectDevice(name: deviceName)
        appDelegate?.settings.selectedSonosDevice = deviceName

        speakerNameLabel.stringValue = deviceName
        populateSpeakers()

        // Update volume slider for the newly selected speaker
        updateVolumeFromSonos()
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
        guard selectedSpeakerCards.count > 1 else {
            print("⚠️ Need at least 2 speakers to create a group")
            return
        }

        // Get the actual device objects
        guard let controller = appDelegate?.sonosController else { return }
        let selectedDevices = controller.discoveredDevices.filter { selectedSpeakerCards.contains($0.name) }

        guard selectedDevices.count == selectedSpeakerCards.count else {
            print("⚠️ Could not find all selected devices")
            return
        }

        print("🎵 Creating group with \(selectedDevices.count) speakers:")
        for device in selectedDevices {
            print("  - \(device.name)")
        }

        // Disable button during operation
        groupButton.isEnabled = false
        groupButton.title = "Grouping..."

        // Create the group
        controller.createGroup(devices: selectedDevices) { [weak self] success in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if success {
                    print("✅ Group created successfully!")

                    // Clear selections
                    self.selectedSpeakerCards.removeAll()

                    // Reset button
                    self.groupButton.title = "Group Selected"
                    self.groupButton.isEnabled = false

                    // Refresh UI to show new groups
                    self.populateSpeakers()

                    // Update volume slider if one of the grouped speakers was selected
                    if let selectedDevice = self.appDelegate?.settings.selectedSonosDevice,
                       selectedDevices.contains(where: { $0.name == selectedDevice }) {
                        self.updateVolumeFromSonos()
                    }
                } else {
                    print("❌ Failed to create group")

                    // Show error HUD
                    Task { @MainActor in
                        VolumeHUD.shared.showError(
                            title: "Grouping Failed",
                            message: "Could not create speaker group"
                        )
                    }

                    // Re-enable button
                    self.groupButton.isEnabled = true
                    self.groupButton.title = "Group \(self.selectedSpeakerCards.count) Speakers"
                }
            }
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
        // Don't fetch volume here - it will be updated via notification after device selection
    }

    private func updateVolumeFromSonos() {
        // Update volume type label
        updateVolumeTypeLabel()

        appDelegate?.sonosController.getVolume { [weak self] volume in
            DispatchQueue.main.async {
                guard let self = self else { return }

                self.volumeSlider.doubleValue = Double(volume)
                self.volumeLabel.stringValue = "\(volume)%"
                self.volumeLabel.textColor = .labelColor

                // Enable slider now that we have actual volume
                if !self.volumeSlider.isEnabled {
                    self.volumeSlider.isEnabled = true
                }
            }
        }
    }

    private func updateVolumeTypeLabel() {
        guard let selectedDeviceName = appDelegate?.settings.selectedSonosDevice,
              let device = appDelegate?.sonosController.discoveredDevices.first(where: { $0.name == selectedDeviceName }),
              let group = appDelegate?.sonosController.getGroupForDevice(device) else {
            volumeTypeLabel.stringValue = "Volume"
            volumeTypeLabel.textColor = .secondaryLabelColor
            return
        }

        // Device is in a multi-speaker group
        volumeTypeLabel.stringValue = "Group Volume (\(group.members.count) speakers)"
        volumeTypeLabel.textColor = .systemBlue
    }
}