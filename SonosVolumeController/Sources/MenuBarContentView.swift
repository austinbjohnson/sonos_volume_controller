import Cocoa

// Custom view that enforces 380px width for popover sizing
private class FixedWidthView: NSView {
    private var widthConstraint: NSLayoutConstraint?

    override func updateConstraints() {
        super.updateConstraints()

        // Enforce 380px width constraint
        if widthConstraint == nil {
            let constraint = widthAnchor.constraint(equalToConstant: 380)
            constraint.priority = .required
            constraint.isActive = true
            widthConstraint = constraint
        }
    }

    override var fittingSize: NSSize {
        return NSSize(width: 380, height: super.fittingSize.height)
    }

    override var intrinsicContentSize: NSSize {
        return NSSize(width: 380, height: NSView.noIntrinsicMetric)
    }
}

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
    private var ungroupButton: NSButton!
    private var groupProgressIndicator: NSProgressIndicator!
    private var ungroupProgressIndicator: NSProgressIndicator!
    private var powerButton: NSButton!
    private var isLoadingDevices: Bool = false
    private var welcomeBanner: NSView!
    private var permissionBanner: NSView!
    private var scrollViewHeightConstraint: NSLayoutConstraint!
    private var containerView: NSView!
    private var welcomeBannerHeightConstraint: NSLayoutConstraint!
    private var permissionBannerHeightConstraint: NSLayoutConstraint!
    private var isPopulatingInProgress: Bool = false  // Prevent multiple simultaneous populates
    private var triggerDeviceLabel: NSTextField!  // Display current audio trigger device
    private var isAdjustingGroupVolume: Bool = false  // Track when group volume is being adjusted
    private var pendingGroupVolumeUpdate: Int?  // Store latest volume from Sonos while user drags
    private var groupVolumeResetTimer: Timer?  // Debounce network updates until drag settles
    private var memberVolumeThrottleTimer: Timer?  // Throttle member volume refresh calls

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        // Main container - width fixed at 380px via custom fittingSize, height dynamic
        containerView = FixedWidthView(frame: NSRect(x: 0, y: 0, width: 380, height: 500))
        self.view = containerView

        // Set preferred content size to prevent auto-sizing
        self.preferredContentSize = NSSize(width: 380, height: 500)

        // Single glass effect view
        glassView = NSGlassEffectView()
        glassView.cornerRadius = 24
        glassView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(glassView)

        // Main content container - constrain to exact width
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        glassView.contentView = contentView

        // Force contentView to be exactly 380px minus margins (2 * 8px = 16px)
        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalToConstant: 364)
        ])

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

        // Note: devicesDiscovered is handled by AppDelegate which calls refresh()
        // No need to observe it here to avoid duplicate populateSpeakers() calls
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Now that view is loaded, populate speakers with proper layout
        populateSpeakers()

        // Listen for permission status changes to update banner
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePermissionStatusChanged(_:)),
            name: NSNotification.Name("PermissionStatusChanged"),
            object: nil
        )

        // Listen for trigger device changes to update display
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTriggerDeviceChanged(_:)),
            name: NSNotification.Name("TriggerDeviceDidChange"),
            object: nil
        )
    }

    @objc private func handlePermissionStatusChanged(_ notification: Notification) {
        // Refresh to update permission banner visibility
        Task { @MainActor in
            self.populateSpeakers()
        }
    }

    @objc private func handleTriggerDeviceChanged(_ notification: Notification) {
        // Update trigger device label with new value
        Task { @MainActor in
            self.updateTriggerDeviceLabel()
        }
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
        let currentSpeaker = appDelegate?.settings.lastActiveSpeaker ?? "No Speaker"
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
        // Volume type label (shows "Volume" or "Group Volume (X speakers)")
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
        volumeSlider.isContinuous = true // Real-time updates while dragging
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

        // Permission banner (shows when accessibility permission not granted)
        permissionBanner = createPermissionBanner()
        container.addSubview(permissionBanner)

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
        if appDelegate?.sonosController.cachedDiscoveredDevices.isEmpty != false {
            isLoadingDevices = true
        }

        // Don't populate here - will be called after view is loaded
        scrollView.documentView = speakerCardsContainer

        // Group button
        groupButton = NSButton()
        groupButton.title = "Group Selected"
        groupButton.bezelStyle = .rounded
        groupButton.controlSize = .small
        groupButton.target = self
        groupButton.action = #selector(groupSpeakers)
        groupButton.isEnabled = false
        groupButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(groupButton)

        // Ungroup button
        ungroupButton = NSButton()
        ungroupButton.title = "Ungroup Selected"
        ungroupButton.bezelStyle = .rounded
        ungroupButton.controlSize = .small
        ungroupButton.target = self
        ungroupButton.action = #selector(ungroupSelected)
        ungroupButton.isEnabled = false
        ungroupButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(ungroupButton)

        // Progress indicators for buttons
        groupProgressIndicator = NSProgressIndicator()
        groupProgressIndicator.style = .spinning
        groupProgressIndicator.controlSize = .small
        groupProgressIndicator.isDisplayedWhenStopped = false
        groupProgressIndicator.translatesAutoresizingMaskIntoConstraints = false
        groupButton.addSubview(groupProgressIndicator)

        ungroupProgressIndicator = NSProgressIndicator()
        ungroupProgressIndicator.style = .spinning
        ungroupProgressIndicator.controlSize = .small
        ungroupProgressIndicator.isDisplayedWhenStopped = false
        ungroupProgressIndicator.translatesAutoresizingMaskIntoConstraints = false
        ungroupButton.addSubview(ungroupProgressIndicator)

        // Divider
        let divider3 = createDivider()
        container.addSubview(divider3)

        // Find the previous divider to anchor to
        let previousDividers = container.subviews.compactMap { $0 as? NSBox }
        let previousDivider = previousDividers[previousDividers.count - 2]

        // Create height constraints for dynamic sizing
        scrollViewHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 200)
        permissionBannerHeightConstraint = permissionBanner.heightAnchor.constraint(equalToConstant: 0) // Start hidden
        welcomeBannerHeightConstraint = welcomeBanner.heightAnchor.constraint(equalToConstant: 0) // Start hidden

        NSLayoutConstraint.activate([
            speakersTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            speakersTitle.topAnchor.constraint(equalTo: previousDivider.bottomAnchor, constant: 12),

            permissionBanner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            permissionBanner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            permissionBanner.topAnchor.constraint(equalTo: speakersTitle.bottomAnchor, constant: 12),
            permissionBannerHeightConstraint,

            welcomeBanner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            welcomeBanner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            welcomeBanner.topAnchor.constraint(equalTo: permissionBanner.bottomAnchor, constant: 8),
            welcomeBannerHeightConstraint,

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            scrollView.topAnchor.constraint(equalTo: welcomeBanner.bottomAnchor, constant: 8),
            scrollViewHeightConstraint,

            speakerCardsContainer.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            // Position buttons side by side
            groupButton.trailingAnchor.constraint(equalTo: container.centerXAnchor, constant: -6),
            groupButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),

            ungroupButton.leadingAnchor.constraint(equalTo: container.centerXAnchor, constant: 6),
            ungroupButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),

            // Progress indicator positions (leading edge of buttons)
            groupProgressIndicator.leadingAnchor.constraint(equalTo: groupButton.leadingAnchor, constant: 12),
            groupProgressIndicator.centerYAnchor.constraint(equalTo: groupButton.centerYAnchor),
            groupProgressIndicator.widthAnchor.constraint(equalToConstant: 12),
            groupProgressIndicator.heightAnchor.constraint(equalToConstant: 12),

            ungroupProgressIndicator.leadingAnchor.constraint(equalTo: ungroupButton.leadingAnchor, constant: 12),
            ungroupProgressIndicator.centerYAnchor.constraint(equalTo: ungroupButton.centerYAnchor),
            ungroupProgressIndicator.widthAnchor.constraint(equalToConstant: 12),
            ungroupProgressIndicator.heightAnchor.constraint(equalToConstant: 12),

            divider3.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            divider3.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            divider3.topAnchor.constraint(equalTo: groupButton.bottomAnchor, constant: 16),
            divider3.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    // Create a card for a multi-speaker group
    private func createGroupCard(group: SonosController.SonosGroup, isActive: Bool) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = isActive ?
            NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor :
            NSColor.labelColor.withAlphaComponent(0.03).cgColor
        card.layer?.cornerRadius = 10
        card.translatesAutoresizingMaskIntoConstraints = false

        // Active indicator (blue dot) - non-interactive visual indicator
        let activeIndicator = NSView()
        if isActive {
            activeIndicator.wantsLayer = true
            activeIndicator.layer?.backgroundColor = NSColor.systemBlue.cgColor
            activeIndicator.layer?.cornerRadius = 4
            activeIndicator.toolTip = "Currently active"
        }
        activeIndicator.translatesAutoresizingMaskIntoConstraints = false

        // Group icon (multiple speakers)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "hifispeaker.2.fill", accessibilityDescription: "Group")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        icon.contentTintColor = isActive ? .controlAccentColor : .systemBlue
        icon.translatesAutoresizingMaskIntoConstraints = false

        // Group name
        let nameLabel = NSTextField(labelWithString: group.name)
        nameLabel.font = .systemFont(ofSize: 13, weight: isActive ? .semibold : .medium)
        nameLabel.textColor = isActive ? .labelColor : .labelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        // Selection checkbox for ungrouping
        let checkbox = NSButton()
        checkbox.setButtonType(.switch)
        checkbox.controlSize = .small
        checkbox.title = ""
        checkbox.state = selectedSpeakerCards.contains(group.id) ? .on : .off
        checkbox.target = self
        checkbox.action = #selector(speakerSelectionChanged(_:))
        checkbox.identifier = NSUserInterfaceItemIdentifier(group.id)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.toolTip = "Select for ungrouping"
        // Hidden by default, shown on hover (unless already checked)
        checkbox.isHidden = (checkbox.state != .on)

        // Card identifier for tracking (use coordinator UUID for Now Playing lookup)
        card.identifier = NSUserInterfaceItemIdentifier(group.coordinator.uuid)

        // Add tracking area for hover detection
        let trackingArea = NSTrackingArea(
            rect: card.bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: ["checkbox": checkbox]
        )
        card.addTrackingArea(trackingArea)

        // Add click gesture to card (since we removed the interactive star button)
        let cardClick = NSClickGestureRecognizer(target: self, action: #selector(selectGroup(_:)))
        cardClick.delegate = self
        card.addGestureRecognizer(cardClick)

        card.addSubview(activeIndicator)
        card.addSubview(icon)
        card.addSubview(nameLabel)
        card.addSubview(checkbox)

        NSLayoutConstraint.activate([
            // Active indicator (blue dot) on the left
            activeIndicator.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            activeIndicator.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            activeIndicator.widthAnchor.constraint(equalToConstant: 8),
            activeIndicator.heightAnchor.constraint(equalToConstant: 8),

            // Position icon after active indicator (no chevron)
            icon.leadingAnchor.constraint(equalTo: activeIndicator.trailingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            // Position name after icon
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: checkbox.leadingAnchor, constant: -10),

            // Checkbox stays on right (aligned with speaker checkboxes)
            checkbox.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            checkbox.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            card.heightAnchor.constraint(equalToConstant: 42)
        ])

        return card
    }

    // Create a card for a member within an expanded group
    private func createMemberCard(device: SonosController.SonosDevice) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.02).cgColor
        card.layer?.cornerRadius = 8
        card.translatesAutoresizingMaskIntoConstraints = false

        // Blue connection line
        let connectionLine = NSView()
        connectionLine.wantsLayer = true
        connectionLine.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
        connectionLine.translatesAutoresizingMaskIntoConstraints = false

        // Speaker icon
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: "Speaker")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        icon.contentTintColor = .tertiaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        // Speaker name
        let nameLabel = NSTextField(labelWithString: device.name)
        nameLabel.font = .systemFont(ofSize: 12, weight: .regular)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        // Volume slider for this individual speaker
        let volumeSlider = NSSlider()
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 100
        volumeSlider.doubleValue = 50
        volumeSlider.controlSize = .small
        volumeSlider.target = self
        volumeSlider.action = #selector(memberVolumeChanged(_:))
        volumeSlider.identifier = NSUserInterfaceItemIdentifier(device.uuid)
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.isContinuous = true // Real-time updates while dragging

        // Load actual individual volume (bypassing group logic)
        Task { @MainActor in
            await appDelegate?.sonosController.getIndividualVolume(device: device) { @Sendable [weak volumeSlider] volume in
                DispatchQueue.main.async {
                    if let vol = volume {
                        volumeSlider?.doubleValue = Double(vol)
                    } else {
                        volumeSlider?.doubleValue = 50
                    }
                }
            }
        }

        card.addSubview(connectionLine)
        card.addSubview(icon)
        card.addSubview(nameLabel)
        card.addSubview(volumeSlider)

        NSLayoutConstraint.activate([
            connectionLine.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            connectionLine.topAnchor.constraint(equalTo: card.topAnchor),
            connectionLine.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            connectionLine.widthAnchor.constraint(equalToConstant: 2),

            icon.leadingAnchor.constraint(equalTo: connectionLine.trailingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            volumeSlider.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 38),
            volumeSlider.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            volumeSlider.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8),
            volumeSlider.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),

            card.heightAnchor.constraint(equalToConstant: 62)
        ])

        return card
    }

    // Create a card for an ungrouped speaker
    private func createSpeakerCard(device: SonosController.SonosDevice, isActive: Bool) -> NSView {
        // Check if device is in a multi-speaker group
        let isInGroup = device.groupCoordinatorUUID != nil &&
                       appDelegate?.sonosController.cachedDiscoveredGroups.first(where: {
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

        // Active indicator (blue dot) - non-interactive visual indicator
        let activeIndicator = NSView()
        if isActive {
            activeIndicator.wantsLayer = true
            activeIndicator.layer?.backgroundColor = NSColor.systemBlue.cgColor
            activeIndicator.layer?.cornerRadius = 4
            activeIndicator.toolTip = "Currently active"
        }
        activeIndicator.translatesAutoresizingMaskIntoConstraints = false

        // Speaker icon
        let icon = NSImageView()
        let iconName = isGroupCoordinator ? "person.3.fill" : "hifispeaker.fill"
        icon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Speaker")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        icon.contentTintColor = isGroupCoordinator ? .systemBlue : (isActive ? .controlAccentColor : .tertiaryLabelColor)
        icon.translatesAutoresizingMaskIntoConstraints = false

        // Build display name with group info
        let displayName = device.name

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
            let group = appDelegate?.sonosController.cachedDiscoveredGroups.first(where: {
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
        checkbox.toolTip = "Select for grouping"
        // Hidden by default, shown on hover (unless already checked)
        checkbox.isHidden = (checkbox.state != .on)

        // Card identifier for tracking (use UUID for Now Playing lookup)
        card.identifier = NSUserInterfaceItemIdentifier(device.uuid)

        let leadingOffset: CGFloat = (isInGroup && !isGroupCoordinator) ? 20 : 8

        // Add tracking area for hover detection
        let trackingArea = NSTrackingArea(
            rect: card.bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: ["checkbox": checkbox]
        )
        card.addTrackingArea(trackingArea)

        // Add click gesture to card (since we removed the interactive star button)
        let cardClick = NSClickGestureRecognizer(target: self, action: #selector(selectSpeaker(_:)))
        cardClick.delegate = self
        card.addGestureRecognizer(cardClick)

        card.addSubview(activeIndicator)
        card.addSubview(icon)
        card.addSubview(textStack)
        card.addSubview(checkbox)

        NSLayoutConstraint.activate([
            // Active indicator (blue dot) on the left
            activeIndicator.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: leadingOffset),
            activeIndicator.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            activeIndicator.widthAnchor.constraint(equalToConstant: 8),
            activeIndicator.heightAnchor.constraint(equalToConstant: 8),

            // Icon follows the active indicator
            icon.leadingAnchor.constraint(equalTo: activeIndicator.trailingAnchor, constant: 8),
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
        // Debounce: prevent multiple simultaneous populate calls
        guard !isPopulatingInProgress else {
            print("⚠️ populateSpeakers already in progress, skipping")
            return
        }

        isPopulatingInProgress = true
        defer {
            isPopulatingInProgress = false
        }

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

        guard let controller = appDelegate?.sonosController,
              !controller.cachedDiscoveredDevices.isEmpty else {
            let label = NSTextField(labelWithString: "No speakers found")
            label.alignment = .center
            label.textColor = .tertiaryLabelColor
            label.font = .systemFont(ofSize: 13)
            speakerCardsContainer.addArrangedSubview(label)
            return
        }

        let currentSpeaker = appDelegate?.settings.lastActiveSpeaker
        let groups = controller.cachedDiscoveredGroups
        let devices = controller.cachedDiscoveredDevices

        // Show/hide permission banner based on accessibility permission status
        let hasPermission = appDelegate?.settings.isAccessibilityPermissionGranted ?? true
        if let banner = permissionBanner, let heightConstraint = permissionBannerHeightConstraint {
            banner.isHidden = hasPermission
            // Collapse height when hidden to prevent ghost spacing
            heightConstraint.constant = hasPermission ? 0 : 60
        }

        // Show/hide welcome banner based on whether a speaker is selected
        let shouldShowBanner = currentSpeaker?.isEmpty ?? true
        if let banner = welcomeBanner, let heightConstraint = welcomeBannerHeightConstraint {
            banner.isHidden = !shouldShowBanner
            // Collapse height when hidden to prevent ghost spacing
            heightConstraint.constant = shouldShowBanner ? 50 : 0
        }

        // Find devices that are in multi-speaker groups
        let devicesInGroups = Set(groups.filter { $0.members.count > 1 }.flatMap { $0.members.map { $0.uuid } })

        // Sort groups alphabetically (consistent ordering)
        let sortedGroups = groups.filter { $0.members.count > 1 }.sorted { group1, group2 in
            return group1.name.localizedCaseInsensitiveCompare(group2.name) == .orderedAscending
        }

        // Sort ungrouped devices alphabetically (consistent ordering)
        let ungroupedDevices = devices.filter { !devicesInGroups.contains($0.uuid) }.sorted { device1, device2 in
            return device1.name.localizedCaseInsensitiveCompare(device2.name) == .orderedAscending
        }

        // Add groups first
        for group in sortedGroups {
            let isActive = group.members.contains(where: { $0.name == currentSpeaker })
            let groupCard = createGroupCard(group: group, isActive: isActive)
            speakerCardsContainer.addArrangedSubview(groupCard)

            // Force consistent width
            NSLayoutConstraint.activate([
                groupCard.widthAnchor.constraint(equalTo: speakerCardsContainer.widthAnchor)
            ])

            // Always show member cards (groups always expanded)
            for member in group.members.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
                let memberCard = createMemberCard(device: member)
                // Add left padding for indentation
                let paddedContainer = NSView()
                paddedContainer.translatesAutoresizingMaskIntoConstraints = false
                paddedContainer.identifier = NSUserInterfaceItemIdentifier("\(group.id)_member_\(member.uuid)")
                paddedContainer.addSubview(memberCard)

                NSLayoutConstraint.activate([
                    memberCard.leadingAnchor.constraint(equalTo: paddedContainer.leadingAnchor, constant: 20),
                    memberCard.trailingAnchor.constraint(equalTo: paddedContainer.trailingAnchor),
                    memberCard.topAnchor.constraint(equalTo: paddedContainer.topAnchor),
                    memberCard.bottomAnchor.constraint(equalTo: paddedContainer.bottomAnchor)
                ])

                speakerCardsContainer.addArrangedSubview(paddedContainer)
            }
        }

        // Then add ungrouped speakers
        for device in ungroupedDevices {
            let isActive = device.name == currentSpeaker
            let card = createSpeakerCard(device: device, isActive: isActive)
            speakerCardsContainer.addArrangedSubview(card)

            // Force consistent width
            NSLayoutConstraint.activate([
                card.widthAnchor.constraint(equalTo: speakerCardsContainer.widthAnchor)
            ])
        }

        // Update volume type label
        updateVolumeTypeLabel()

        // Fetch Now Playing info for all devices (async)
        fetchNowPlayingInfo(for: devices)

        // Force scroll to top to ensure header is visible
        if let scrollView = speakerCardsContainer.enclosingScrollView {
            scrollView.documentView?.scroll(NSPoint.zero)
            scrollView.contentView.scroll(to: NSPoint.zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // Update popover size after initial populate
        // Force layout to complete before calculating heights
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Force layout on all card subviews to ensure heights are calculated
            self.speakerCardsContainer.layoutSubtreeIfNeeded()
            self.containerView.layoutSubtreeIfNeeded()

            // Force scroll to top again after layout
            if let scrollView = self.speakerCardsContainer.enclosingScrollView {
                scrollView.documentView?.scroll(NSPoint.zero)
                scrollView.contentView.scroll(to: NSPoint.zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }

            self.updatePopoverSize(animated: false)
        }
    }

    /// Fetch Now Playing info for all devices in parallel
    private func fetchNowPlayingInfo(for devices: [SonosController.SonosDevice]) {
        guard let controller = appDelegate?.sonosController else { return }

        Task {
            // Fetch audio source info for all devices in parallel
            var results: [(String, String?, SonosController.AudioSourceType?, SonosController.NowPlayingInfo?)] = []

            await withTaskGroup(of: (String, String?, SonosController.AudioSourceType?, SonosController.NowPlayingInfo?).self) { group in
                for device in devices {
                    group.addTask {
                        if let info = await controller.getAudioSourceInfo(for: device) {
                            return (device.uuid, info.state, info.sourceType, info.nowPlaying)
                        }
                        return (device.uuid, nil, nil, nil)
                    }
                }

                // Collect all results first
                for await result in group {
                    results.append(result)
                }
            }

            // Apply all updates at once on main actor
            await MainActor.run {
                for (uuid, state, sourceType, nowPlaying) in results {
                    self.updateCardWithNowPlaying(uuid: uuid, state: state, sourceType: sourceType, nowPlaying: nowPlaying, skipResize: true)
                }
                // Resize popover once after all updates
                self.updatePopoverSize(animated: true, duration: 0.15)
            }
        }
    }

    /// Update a specific card with Now Playing info
    @MainActor
    private func updateCardWithNowPlaying(uuid: String, state: String?, sourceType: SonosController.AudioSourceType?, nowPlaying: SonosController.NowPlayingInfo?, skipResize: Bool = false) {
        // Find the card by UUID (stored in identifier)
        for subview in speakerCardsContainer.arrangedSubviews {
            if subview.identifier?.rawValue == uuid {
                // Add Now Playing label if we have metadata
                if let nowPlaying = nowPlaying, let sourceType = sourceType, sourceType == .streaming {
                    addNowPlayingLabel(to: subview, text: nowPlaying.displayText, albumArtURL: nowPlaying.albumArtURL, sourceType: sourceType, skipResize: skipResize)
                } else if let sourceType = sourceType, sourceType == .lineIn {
                    addNowPlayingLabel(to: subview, text: "Line-In Audio", albumArtURL: nil, sourceType: sourceType, skipResize: skipResize)
                } else if let sourceType = sourceType, sourceType == .tv {
                    addNowPlayingLabel(to: subview, text: "TV Audio", albumArtURL: nil, sourceType: sourceType, skipResize: skipResize)
                }

                // Add colored badge
                if let sourceType = sourceType {
                    addSourceBadge(to: subview, sourceType: sourceType)
                }

                break
            }
        }
    }

    /// Add Now Playing text label to card
    private func addNowPlayingLabel(to card: NSView, text: String, albumArtURL: String? = nil, sourceType: SonosController.AudioSourceType = .streaming, skipResize: Bool = false) {
        let nowPlayingLabel = NSTextField(labelWithString: text)
        nowPlayingLabel.font = .systemFont(ofSize: 11, weight: .regular)
        nowPlayingLabel.textColor = .secondaryLabelColor
        nowPlayingLabel.lineBreakMode = .byTruncatingMiddle
        nowPlayingLabel.maximumNumberOfLines = 1
        nowPlayingLabel.translatesAutoresizingMaskIntoConstraints = false
        nowPlayingLabel.identifier = NSUserInterfaceItemIdentifier("nowPlayingLabel")

        card.addSubview(nowPlayingLabel)

        // Add album art image view
        addAlbumArtImage(to: card, url: albumArtURL, sourceType: sourceType)

        // Check if this is a group card or speaker card
        // Group cards have an NSImageView with "hifispeaker.2.fill" icon
        let hasGroupIcon = card.subviews.contains { view in
            if let imageView = view as? NSImageView,
               let imageName = imageView.image?.name(),
               imageName.contains("hifispeaker.2") {
                return true
            }
            return false
        }

        if hasGroupIcon {
            // GROUP CARD: Find nameLabel and reposition after album art
            if let nameLabel = card.subviews.first(where: { $0 is NSTextField && $0.identifier == nil }) as? NSTextField {
                // Remove existing leading constraint
                let constraintsToRemove = card.constraints.filter { constraint in
                    (constraint.firstItem as? NSTextField == nameLabel && constraint.firstAttribute == .leading) ||
                    (constraint.secondItem as? NSTextField == nameLabel && constraint.secondAttribute == .leading)
                }
                NSLayoutConstraint.deactivate(constraintsToRemove)

                // Position after album art (46 + 40 + 8 = 94pt)
                nameLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 94).isActive = true
            }
        } else {
            // SPEAKER CARD: Find textStack and reposition it
            if let textStack = card.subviews.first(where: { $0 is NSStackView }) as? NSStackView {
                // Remove the centerY and leading constraints on textStack
                let constraintsToRemove = card.constraints.filter { constraint in
                    (constraint.firstItem as? NSStackView == textStack && (constraint.firstAttribute == .centerY || constraint.firstAttribute == .leading)) ||
                    (constraint.secondItem as? NSStackView == textStack && (constraint.secondAttribute == .centerY || constraint.secondAttribute == .leading))
                }
                NSLayoutConstraint.deactivate(constraintsToRemove)

                // Pin textStack to top and move right to accommodate album art (12 + 40 + 8 = 60pt)
                NSLayoutConstraint.activate([
                    textStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
                    textStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 60)
                ])
            }

            // Hide icon and indicator for speaker cards (replaced by album art)
            if let icon = card.subviews.first(where: { $0 is NSImageView && $0.identifier?.rawValue != "albumArtImageView" }) as? NSImageView {
                icon.isHidden = true
            }

            let activeIndicator = card.subviews.first { view in
                view.layer?.backgroundColor == NSColor.systemBlue.cgColor && view.layer?.cornerRadius == 4
            }
            if let indicator = activeIndicator {
                indicator.isHidden = true
            }
        }

        // Position now playing label below the speaker/group name, accounting for album art
        let nowPlayingLeading: CGFloat = hasGroupIcon ? 94 : 60  // Group cards have album art further right
        NSLayoutConstraint.activate([
            nowPlayingLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: nowPlayingLeading), // After album art
            nowPlayingLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -40), // Leave room for badge
            nowPlayingLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 34) // Below name at top:10 with tighter spacing
        ])

        // Replace greaterThanOrEqual constraint with fixed 64pt height
        let heightConstraintsToRemove = card.constraints.filter { $0.firstAttribute == .height }
        NSLayoutConstraint.deactivate(heightConstraintsToRemove)
        card.heightAnchor.constraint(equalToConstant: 64).isActive = true

        // Force layout update
        card.needsLayout = true
        card.layoutSubtreeIfNeeded()

        // Update popover size to accommodate expanded cards (unless batching)
        if !skipResize {
            updatePopoverSize(animated: true, duration: 0.15)
        }
    }

    /// Add album art image to card with fallback SF Symbol
    private func addAlbumArtImage(to card: NSView, url: String?, sourceType: SonosController.AudioSourceType) {
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.identifier = NSUserInterfaceItemIdentifier("albumArtImageView")
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 0.5
        imageView.layer?.borderColor = NSColor.separatorColor.cgColor

        card.addSubview(imageView)

        // Check if this is a group card or regular speaker card
        // Group cards have an NSImageView with "hifispeaker.2.fill" icon
        let hasGroupIcon = card.subviews.contains { view in
            if let imageView = view as? NSImageView,
               let imageName = imageView.image?.name(),
               imageName.contains("hifispeaker.2") {
                return true
            }
            return false
        }

        // Position: For group cards, place after group icon (~46pt = 8+8+20+10). For speaker cards, at leading +12pt
        let leadingConstant: CGFloat = hasGroupIcon ? 46 : 12

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 40),
            imageView.heightAnchor.constraint(equalToConstant: 40),
            imageView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: leadingConstant),
            imageView.centerYAnchor.constraint(equalTo: card.centerYAnchor)
        ])

        // Set fallback SF Symbol based on source type
        let fallbackSymbol: String
        switch sourceType {
        case .streaming:
            fallbackSymbol = "music.note"
        case .lineIn:
            fallbackSymbol = "waveform"
        case .tv:
            fallbackSymbol = "tv"
        default:
            fallbackSymbol = "music.note"
        }

        // Create SF Symbol image with gray background
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        if let symbolImage = NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) {
            let fallbackImage = NSImage(size: NSSize(width: 40, height: 40))
            fallbackImage.lockFocus()

            // Gray background
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 40, height: 40)).fill()

            // Center the symbol
            let symbolSize = symbolImage.size
            let x = (40 - symbolSize.width) / 2
            let y = (40 - symbolSize.height) / 2
            symbolImage.draw(at: NSPoint(x: x, y: y), from: .zero, operation: .sourceOver, fraction: 0.5)

            fallbackImage.unlockFocus()
            imageView.image = fallbackImage
        }

        // Async load album art if URL provided
        if let urlString = url, let controller = appDelegate?.sonosController {
            Task {
                if let albumArt = await controller.fetchAlbumArt(url: urlString) {
                    await MainActor.run {
                        imageView.image = albumArt
                    }
                }
            }
        }
    }

    /// Add colored source badge to card
    private func addSourceBadge(to card: NSView, sourceType: SonosController.AudioSourceType) {
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.identifier = NSUserInterfaceItemIdentifier("sourceBadge")

        // Set badge color based on source type
        let badgeColor: NSColor
        switch sourceType {
        case .streaming:
            badgeColor = .systemGreen
        case .lineIn, .tv:
            badgeColor = .systemBlue
        case .grouped:
            badgeColor = NSColor.systemYellow.withAlphaComponent(0.8)
        case .idle:
            badgeColor = .tertiaryLabelColor
        }

        badge.layer?.backgroundColor = badgeColor.cgColor
        card.addSubview(badge)

        // Position in top-right corner
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 10),
            badge.heightAnchor.constraint(equalToConstant: 10),
            badge.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            badge.topAnchor.constraint(equalTo: card.topAnchor, constant: 6)
        ])

        // Add pulse animation for active playback
        if sourceType == .streaming || sourceType == .lineIn || sourceType == .tv {
            addPulseAnimation(to: badge.layer!)
        }
    }

    /// Add pulse animation to layer
    private func addPulseAnimation(to layer: CALayer) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.7
        animation.toValue = 1.0
        animation.duration = 2.0
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "pulse")
    }

    private func updateVolumeTypeLabel() {
        guard let device = appDelegate?.sonosController.cachedSelectedDevice,
              let group = appDelegate?.sonosController.getCachedGroupForDevice(device) else {
            volumeTypeLabel.stringValue = "Volume"
            volumeTypeLabel.textColor = .secondaryLabelColor
            volumeTypeLabel.font = .systemFont(ofSize: 11, weight: .medium)
            return
        }

        volumeTypeLabel.stringValue = "Group Volume (\(group.members.count) speakers)"
        volumeTypeLabel.textColor = .systemBlue
        volumeTypeLabel.font = .systemFont(ofSize: 11, weight: .semibold) // Bolder for groups
    }

    // MARK: - Trigger Device Section

    private func setupTriggerDeviceSection(in container: NSView) {
        // Section title
        let triggerTitle = NSTextField(labelWithString: "Audio Trigger")
        triggerTitle.font = .systemFont(ofSize: 13, weight: .medium)
        triggerTitle.textColor = .secondaryLabelColor
        triggerTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(triggerTitle)

        // Get current trigger device setting
        guard let settings = appDelegate?.settings else { return }
        let currentTrigger = settings.triggerDeviceName

        // Display current trigger device (read-only)
        let triggerDevice = currentTrigger.isEmpty ? "Any Device" : currentTrigger
        triggerDeviceLabel = NSTextField(labelWithString: triggerDevice)
        triggerDeviceLabel.font = .systemFont(ofSize: 12, weight: .regular)
        triggerDeviceLabel.textColor = .labelColor
        triggerDeviceLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(triggerDeviceLabel)

        // Divider
        let divider4 = createDivider()
        container.addSubview(divider4)

        // Find the previous divider to anchor to
        let previousDividers = container.subviews.compactMap { $0 as? NSBox }
        let previousDivider = previousDividers[previousDividers.count - 2]

        NSLayoutConstraint.activate([
            triggerTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            triggerTitle.topAnchor.constraint(equalTo: previousDivider.bottomAnchor, constant: 12),

            triggerDeviceLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            triggerDeviceLabel.topAnchor.constraint(equalTo: triggerTitle.bottomAnchor, constant: 4),

            divider4.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            divider4.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            divider4.topAnchor.constraint(equalTo: triggerDeviceLabel.bottomAnchor, constant: 12),
            divider4.heightAnchor.constraint(equalToConstant: 1)
        ])
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
        let text = NSTextField(labelWithString: "Welcome! Click any speaker below to start controlling it with volume hotkeys.")
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

    private func createPermissionBanner() -> NSView {
        let banner = NSView()
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.15).cgColor
        banner.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.3).cgColor
        banner.layer?.borderWidth = 1
        banner.layer?.cornerRadius = 6
        banner.translatesAutoresizingMaskIntoConstraints = false

        // Warning icon
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        icon.contentTintColor = .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false

        // Warning text
        let text = NSTextField(labelWithString: "Hotkeys require accessibility permission")
        text.font = .systemFont(ofSize: 13, weight: .medium)
        text.textColor = .labelColor
        text.alignment = .left
        text.translatesAutoresizingMaskIntoConstraints = false

        // Link button
        let linkButton = NSButton()
        linkButton.title = "Enable in System Settings →"
        linkButton.bezelStyle = .inline
        linkButton.isBordered = false
        linkButton.font = .systemFont(ofSize: 13, weight: .medium)
        linkButton.contentTintColor = .systemBlue
        linkButton.target = self
        linkButton.action = #selector(openAccessibilitySettings)
        linkButton.translatesAutoresizingMaskIntoConstraints = false

        banner.addSubview(icon)
        banner.addSubview(text)
        banner.addSubview(linkButton)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: banner.topAnchor, constant: 10),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
            text.topAnchor.constraint(equalTo: banner.topAnchor, constant: 10),

            linkButton.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            linkButton.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 2),
            linkButton.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -10)
        ])

        // Initially hidden - will be shown when permission not granted
        banner.isHidden = true

        return banner
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
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

        print("📊 [UI] Volume slider changed to: \(volume)%")

        // Mark that we're adjusting group volume
        isAdjustingGroupVolume = true
        groupVolumeResetTimer?.invalidate()
        pendingGroupVolumeUpdate = nil
        updateMemberCardVisualState(isGroupAdjusting: true)

        // Visual feedback: briefly highlight the label
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            volumeLabel.textColor = .systemBlue
        }, completionHandler: {
            Task { @MainActor in
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.3
                    self.volumeLabel.textColor = .labelColor
                })
            }
        })

        // Set the actual Sonos volume using absolute SetGroupVolume
        // According to Sonos docs, this should maintain speaker ratios
        Task {
            print("📊 [UI] Calling setVolume(\(volume)) - should maintain speaker ratios per Sonos docs")
            await appDelegate?.sonosController.setVolume(volume)

            // After setting group volume, refresh all member volumes
            // (Sonos adjusts member volumes proportionally)
            await MainActor.run {
                print("📊 [UI] Refreshing member volumes to reflect changes")
                self.refreshMemberVolumes()
                self.scheduleGroupVolumeAdjustmentReset()
            }
        }
    }

    @objc private func volumeDidChange(_ notification: Notification) {
        // Update slider when volume changes via hotkeys or initial load
        guard let userInfo = notification.userInfo,
              let volume = userInfo["volume"] as? Int else { return }

        print("📊 [UI] Volume notification received: \(volume)%")

        if isAdjustingGroupVolume {
            pendingGroupVolumeUpdate = volume
            return
        }

        applyGroupVolumeUpdate(volume, refreshMembers: true)
    }

    private func applyGroupVolumeUpdate(_ volume: Int, refreshMembers: Bool) {
        volumeSlider.doubleValue = Double(volume)
        volumeLabel.stringValue = "\(volume)%"
        volumeLabel.textColor = .labelColor

        if !volumeSlider.isEnabled {
            volumeSlider.isEnabled = true
        }

        if refreshMembers {
            refreshMemberVolumes()
        }
    }

    private func applyPendingGroupVolumeIfNeeded() {
        guard let pendingVolume = pendingGroupVolumeUpdate else { return }
        pendingGroupVolumeUpdate = nil
        applyGroupVolumeUpdate(pendingVolume, refreshMembers: true)
    }

    private func scheduleGroupVolumeAdjustmentReset() {
        groupVolumeResetTimer?.invalidate()
        groupVolumeResetTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isAdjustingGroupVolume = false
                self.updateMemberCardVisualState(isGroupAdjusting: false)
                self.applyPendingGroupVolumeIfNeeded()
                self.groupVolumeResetTimer = nil
            }
        }
    }

    private func refreshMemberVolumes() {
        // Throttle member volume updates to prevent excessive network requests
        memberVolumeThrottleTimer?.invalidate()
        memberVolumeThrottleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.memberVolumeThrottleTimer = nil
                self.performMemberVolumeRefresh()
            }
        }
    }

    private func performMemberVolumeRefresh() {
        // Find all member card containers (paddedContainer wrapping the actual member card)
        let memberContainers = speakerCardsContainer.arrangedSubviews.filter { view in
            guard let identifier = view.identifier?.rawValue else { return false }
            return identifier.contains("_member_")
        }

        print("📊 [UI] Refreshing \(memberContainers.count) member speaker volumes...")

        for paddedContainer in memberContainers {
            // Navigate: paddedContainer -> memberCard -> find slider
            guard let memberCard = paddedContainer.subviews.first else { continue }

            // Find the volume slider in the actual member card
            if let volumeSlider = memberCard.subviews.compactMap({ $0 as? NSSlider }).first,
               let deviceUUID = volumeSlider.identifier?.rawValue,
               let device = appDelegate?.sonosController.cachedDiscoveredDevices.first(where: { $0.uuid == deviceUUID }) {

                let currentSliderValue = Int(volumeSlider.doubleValue)
                print("📊 [UI] Querying \(device.name) - current UI slider: \(currentSliderValue)%")

                // Refresh this speaker's individual volume
                // Capture container reference for later use
                let containerRef = paddedContainer
                Task { @MainActor in
                    await appDelegate?.sonosController.getIndividualVolume(device: device) { @Sendable volume in
                        guard let vol = volume else { return }

                        print("📊 [UI] ✅ \(device.name) actual volume from Sonos: \(vol)%")

                        Task { @MainActor [weak containerRef] in
                            guard let container = containerRef else { return }

                            // Re-find the slider to ensure it still exists
                            guard let currentCard = container.subviews.first,
                                  let currentSlider = currentCard.subviews.compactMap({ $0 as? NSSlider }).first else {
                                return
                            }

                            print("📊 [UI] Updating \(device.name) slider: \(Int(currentSlider.doubleValue))% → \(vol)%")

                            // Animate slider movement smoothly
                            NSAnimationContext.runAnimationGroup({ context in
                                context.duration = 0.25
                                context.allowsImplicitAnimation = true
                                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                                currentSlider.animator().doubleValue = Double(vol)
                            })
                        }
                    }
                }
            }
        }
    }

    private func updateMemberCardVisualState(isGroupAdjusting: Bool) {
        // Find all member card containers
        let memberContainers = speakerCardsContainer.arrangedSubviews.filter { view in
            guard let identifier = view.identifier?.rawValue else { return false }
            return identifier.contains("_member_")
        }

        for paddedContainer in memberContainers {
            guard let memberCard = paddedContainer.subviews.first else { continue }

            // Find the connection line (first subview, blue vertical line)
            if let connectionLine = memberCard.subviews.first(where: { $0.layer?.backgroundColor != nil && $0.frame.width <= 2 }) {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.4
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

                    if isGroupAdjusting {
                        // Pulse the connection line to show active sync
                        connectionLine.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
                        memberCard.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
                    } else {
                        // Return to normal state
                        connectionLine.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
                        memberCard.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.02).cgColor
                    }
                })
            }
        }
    }

    @objc private func discoveryStarted() {
        // Discovery started, show loading indicator
        isLoadingDevices = true
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

    @objc private func selectSpeaker(_ sender: Any) {
        let deviceName: String

        if let button = sender as? NSButton {
            // Called from star button
            guard let name = button.identifier?.rawValue else { return }
            deviceName = name
        } else if let gesture = sender as? NSClickGestureRecognizer {
            // Legacy: called from card click (no longer used but kept for compatibility)
            guard let card = gesture.view,
                  let uuid = card.identifier?.rawValue,
                  let controller = appDelegate?.sonosController,
                  let device = controller.cachedDiscoveredDevices.first(where: { $0.uuid == uuid }) else { return }
            deviceName = device.name
        } else {
            return
        }

        Task {
            await appDelegate?.sonosController.selectDevice(name: deviceName)
        }
        // Track this speaker as last active
        appDelegate?.settings.trackSpeakerActivity(deviceName)

        speakerNameLabel.stringValue = deviceName
        populateSpeakers()

        // Update volume slider for the newly selected speaker
        updateVolumeFromSonos()
    }

    @objc private func speakerSelectionChanged(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue else { return }

        if sender.state == .on {
            selectedSpeakerCards.insert(identifier)
        } else {
            selectedSpeakerCards.remove(identifier)
        }

        // Check if selected items are groups or individual speakers
        let groups = appDelegate?.sonosController.cachedDiscoveredGroups ?? []
        let selectedGroupIds = selectedSpeakerCards.filter { id in
            groups.contains(where: { $0.id == id && $0.members.count > 1 })
        }
        let selectedSpeakerCount = selectedSpeakerCards.count - selectedGroupIds.count

        // Enable group button if multiple speakers selected (not groups)
        groupButton.isEnabled = selectedSpeakerCount > 1
        groupButton.title = selectedSpeakerCount > 1 ?
            "Group \(selectedSpeakerCount) Speakers" : "Group Selected"

        // Enable ungroup button if any groups selected
        ungroupButton.isEnabled = !selectedGroupIds.isEmpty
        ungroupButton.title = selectedGroupIds.count > 1 ?
            "Ungroup \(selectedGroupIds.count) Groups" : "Ungroup Selected"
    }


    @objc private func selectGroup(_ sender: Any) {
        let groupId: String

        if let button = sender as? NSButton {
            // Called from star button
            guard let id = button.identifier?.rawValue else { return }
            groupId = id
        } else if let gesture = sender as? NSClickGestureRecognizer {
            // Legacy: called from card click (no longer used but kept for compatibility)
            guard let card = gesture.view,
                  let id = card.identifier?.rawValue else { return }
            groupId = id
        } else {
            return
        }

        guard let controller = appDelegate?.sonosController else { return }

        // Find the group and select its coordinator as the active device
        if let group = controller.cachedDiscoveredGroups.first(where: { $0.id == groupId }) {
            Task {
                await appDelegate?.sonosController.selectDevice(name: group.coordinator.name)
            }
            // Track this group as last active
            appDelegate?.settings.trackSpeakerActivity(group.coordinator.name)

            // Update UI to show group name
            speakerNameLabel.stringValue = group.name
            populateSpeakers()

            // Update volume slider for the group
            updateVolumeFromSonos()
        }
    }

    @objc private func memberVolumeChanged(_ sender: NSSlider) {
        guard let deviceUUID = sender.identifier?.rawValue,
              let device = appDelegate?.sonosController.cachedDiscoveredDevices.first(where: { $0.uuid == deviceUUID }) else {
            return
        }

        let volume = Int(sender.doubleValue)

        // Cancel any pending group volume updates (member takes priority)
        memberVolumeThrottleTimer?.invalidate()
        isAdjustingGroupVolume = false

        // Set individual speaker volume within the group
        // This uses RenderingControl service directly, bypassing group volume logic
        Task {
            await appDelegate?.sonosController.setIndividualVolume(device: device, volume: volume)

            // After changing individual speaker, update group volume slider
            // Group volume = average of all member volumes in Sonos
            if let group = await appDelegate?.sonosController.getGroupForDevice(device) {
                await appDelegate?.sonosController.getGroupVolume(group: group) { @Sendable [weak self] newGroupVolume in
                    guard let self = self, let groupVol = newGroupVolume else { return }

                    DispatchQueue.main.async {
                        // Update group volume slider with smooth animation
                        NSAnimationContext.runAnimationGroup({ context in
                            context.duration = 0.25
                            context.allowsImplicitAnimation = true
                            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                            self.volumeSlider.animator().doubleValue = Double(groupVol)
                            self.volumeLabel.stringValue = "\(groupVol)%"
                        })
                    }
                }
            }
        }
    }

    private func updateUngroupButton() {
        guard let controller = appDelegate?.sonosController else {
            ungroupButton.isEnabled = false
            return
        }

        // Check if any selected speakers are in multi-speaker groups
        let selectedDevices = controller.cachedDiscoveredDevices.filter { selectedSpeakerCards.contains($0.name) }
        let groupedDevices = selectedDevices.filter { controller.getCachedGroupForDevice($0) != nil }

        ungroupButton.isEnabled = !groupedDevices.isEmpty
        ungroupButton.title = groupedDevices.count > 1 ?
            "Ungroup \(groupedDevices.count) Speakers" : "Ungroup Selected"
    }

    @objc private func ungroupSelected() {
        guard let controller = appDelegate?.sonosController else { return }

        // Separate selected items into groups and individual devices
        let selectedGroupIds = selectedSpeakerCards.filter { id in
            controller.cachedDiscoveredGroups.contains(where: { $0.id == id && $0.members.count > 1 })
        }

        // For device names, get devices that are in groups
        let deviceNames = selectedSpeakerCards.subtracting(selectedGroupIds)
        let selectedDevices = controller.cachedDiscoveredDevices.filter { deviceNames.contains($0.name) }
        let groupedDevices = selectedDevices.filter { controller.getCachedGroupForDevice($0) != nil }

        let totalOperations = selectedGroupIds.count + groupedDevices.count

        guard totalOperations > 0 else {
            print("⚠️ No grouped speakers selected")
            return
        }

        print("🔓 Ungrouping \(selectedGroupIds.count) group(s) and \(groupedDevices.count) device(s)")

        // Disable button and show progress during operation
        ungroupButton.isEnabled = false
        ungroupButton.title = "Ungrouping..."
        ungroupProgressIndicator.startAnimation(nil)

        // Use a class wrapper to track completion count across async callbacks
        class CompletionTracker: @unchecked Sendable {
            var successCount = 0
            var completionCount = 0
        }
        let tracker = CompletionTracker()

        // Completion handler
        let handleCompletion: @Sendable (Bool) -> Void = { [weak self] success in
            DispatchQueue.main.async {
                tracker.completionCount += 1
                if success {
                    tracker.successCount += 1
                }

                // Check if all operations are complete
                if tracker.completionCount == totalOperations {
                    let allSuccess = tracker.successCount == totalOperations
                    print(allSuccess ? "✅ All items ungrouped" : "⚠️ Some items failed to ungroup (\(tracker.successCount)/\(totalOperations) successful)")

                    // Clear selections
                    self?.selectedSpeakerCards.removeAll()

                    // Reset buttons and hide progress
                    self?.ungroupProgressIndicator.stopAnimation(nil)
                    self?.ungroupButton.title = "Ungroup Selected"
                    self?.ungroupButton.isEnabled = false
                    self?.groupButton.isEnabled = false
                    self?.groupButton.title = "Group Selected"

                    // Refresh UI
                    self?.populateSpeakers()

                    if !allSuccess {
                        Task { @MainActor in
                            VolumeHUD.shared.showError(
                                title: "Ungroup Failed",
                                message: "Could not ungroup all items"
                            )
                        }
                    }
                }
            }
        }

        // Ungroup selected groups
        for groupId in selectedGroupIds {
            if let group = controller.cachedDiscoveredGroups.first(where: { $0.id == groupId }) {
                print("  - Dissolving group: \(group.name)")
                Task {
                    await controller.dissolveGroup(group: group, completion: handleCompletion)
                }
            }
        }

        // Ungroup individual devices
        for device in groupedDevices {
            print("  - Ungrouping device: \(device.name)")
            Task {
                await controller.removeDeviceFromGroup(device: device, completion: handleCompletion)
            }
        }
    }

    @objc private func groupSpeakers() {
        guard selectedSpeakerCards.count > 1 else {
            print("⚠️ Need at least 2 speakers to create a group")
            return
        }

        // Get the actual device objects
        guard let controller = appDelegate?.sonosController else { return }
        let selectedDevices = controller.cachedDiscoveredDevices.filter { selectedSpeakerCards.contains($0.name) }

        guard selectedDevices.count == selectedSpeakerCards.count else {
            print("⚠️ Could not find all selected devices")
            return
        }

        print("🎵 Creating group with \(selectedDevices.count) speakers:")
        for device in selectedDevices {
            print("  - \(device.name)")
        }

        // Disable button and show progress during operation
        groupButton.isEnabled = false
        groupButton.title = "Grouping..."
        groupProgressIndicator.startAnimation(nil)

        // Proceed with smart coordinator selection (backend now handles audio source detection)
        performGrouping(devices: selectedDevices, coordinator: nil)
    }

    private func showSourcePreservationDialog(
        lineInDevices: [SonosController.SonosDevice],
        tvDevices: [SonosController.SonosDevice],
        streamingDevices: [SonosController.SonosDevice],
        allDevices: [SonosController.SonosDevice]
    ) {
        let alert = NSAlert()

        if !lineInDevices.isEmpty {
            let lineInNames = lineInDevices.map { $0.name }.joined(separator: ", ")
            alert.messageText = "Line-In Audio Detected"
            alert.informativeText = """
            \(lineInNames) \(lineInDevices.count == 1 ? "is" : "are") playing from a physical audio input (line-in).

            When grouped, all speakers will play from the line-in source. Any streaming audio will stop.

            The line-in speaker will be used as the group coordinator to preserve the audio.
            """
        } else if !tvDevices.isEmpty {
            let tvNames = tvDevices.map { $0.name }.joined(separator: ", ")
            alert.messageText = "TV Audio Detected"
            alert.informativeText = """
            \(tvNames) \(tvDevices.count == 1 ? "is" : "are") playing TV/home theater audio.

            When grouped, all speakers will play the TV audio. Any streaming audio will stop.

            The TV speaker will be used as the group coordinator to preserve the audio.
            """
        }

        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            print("✅ User confirmed grouping with line-in/TV audio preservation")
            performGrouping(devices: allDevices, coordinator: nil)
        } else {
            print("❌ User cancelled grouping")
            groupProgressIndicator.stopAnimation(nil)
            groupButton.isEnabled = true
            groupButton.title = "Group \(selectedSpeakerCards.count) Speakers"
        }
    }

    private func showCoordinatorSelectionDialog(playingDevices: [SonosController.SonosDevice], allDevices: [SonosController.SonosDevice]) {
        let alert = NSAlert()
        alert.messageText = "Multiple Speakers Playing"
        alert.informativeText = "Multiple speakers are currently playing audio. Which audio stream would you like to keep?\n\nOther speakers will sync to the selected coordinator."
        alert.alertStyle = .informational

        // Add a button for each playing device
        for device in playingDevices {
            alert.addButton(withTitle: device.name)
        }
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        // Map response to device selection
        if response.rawValue >= NSApplication.ModalResponse.alertFirstButtonReturn.rawValue,
           response.rawValue < NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + playingDevices.count {
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let chosenCoordinator = playingDevices[index]
            print("✅ User chose coordinator: \(chosenCoordinator.name)")
            performGrouping(devices: allDevices, coordinator: chosenCoordinator)
        } else {
            // User cancelled
            print("❌ User cancelled grouping")
            groupProgressIndicator.stopAnimation(nil)
            groupButton.isEnabled = true
            groupButton.title = "Group \(selectedSpeakerCards.count) Speakers"
        }
    }

    private func performGrouping(devices: [SonosController.SonosDevice], coordinator: SonosController.SonosDevice?) {
        guard let controller = appDelegate?.sonosController else { return }

        groupButton.title = "Grouping..."

        // Create the group with optional explicit coordinator
        Task {
            await controller.createGroup(devices: devices, coordinatorDevice: coordinator) { [weak self] success in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if success {
                    print("✅ Group created successfully!")

                    // Clear selections
                    self.selectedSpeakerCards.removeAll()

                    // Clear expanded groups so new group appears collapsed

                    // Reset button and hide progress
                    self.groupProgressIndicator.stopAnimation(nil)
                    self.groupButton.title = "Group Selected"
                    self.groupButton.isEnabled = false

                    // Refresh UI to show new groups
                    self.populateSpeakers()

                    // Update volume slider if one of the grouped speakers was selected
                    if let selectedDevice = self.appDelegate?.settings.lastActiveSpeaker,
                       devices.contains(where: { $0.name == selectedDevice }) {
                        self.updateVolumeFromSonos()
                    }
                } else {
                    print("❌ Failed to create group")

                    // Show error HUD with helpful message
                    Task { @MainActor in
                        VolumeHUD.shared.showError(
                            title: "Grouping Failed",
                            message: "Try pausing music on stereo pairs before grouping, or select a different coordinator"
                        )
                    }

                    // Re-enable button and hide progress
                    self.groupProgressIndicator.stopAnimation(nil)
                    self.groupButton.isEnabled = true
                    self.groupButton.title = "Group \(self.selectedSpeakerCards.count) Speakers"
                }
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

    // MARK: - Dynamic Sizing

    private func calculateContentHeight() -> CGFloat {
        print("🔍 [CALC] calculateContentHeight() called")

        // Force layout to ensure all card frames are calculated
        speakerCardsContainer.layoutSubtreeIfNeeded()

        // Calculate total height of speaker cards
        var cardsHeight: CGFloat = 0
        for (index, view) in speakerCardsContainer.arrangedSubviews.enumerated() {
            print("🔍 [CALC] Card \(index): \(view.frame.height)pt")
            cardsHeight += view.frame.height
        }

        // Add spacing between cards (8pt per gap)
        let spacing: CGFloat
        if speakerCardsContainer.arrangedSubviews.count > 1 {
            spacing = CGFloat(speakerCardsContainer.arrangedSubviews.count - 1) * 8
            cardsHeight += spacing
            print("🔍 [CALC] Added spacing: \(spacing)pt")
        }

        // Add bottom padding
        cardsHeight += 8
        print("🔍 [CALC] Final content height: \(cardsHeight)pt (cards: \(speakerCardsContainer.arrangedSubviews.count))")

        return cardsHeight
    }

    private func updatePopoverSize(animated: Bool = true, duration: TimeInterval = 0.25) {
        // Guard against being called before view is loaded
        guard scrollViewHeightConstraint != nil else {
            print("⚠️ updatePopoverSize called before view loaded, skipping")
            return
        }

        let contentHeight = calculateContentHeight()
        let maxScrollHeight: CGFloat = 400 // Max height before scroll appears (increased to accommodate expanded groups)
        let newScrollHeight = min(contentHeight, maxScrollHeight)

        print("🔍 [RESIZE] updatePopoverSize(animated: \(animated), duration: \(duration))")
        print("🔍 [RESIZE] Content height: \(contentHeight), scroll height: \(newScrollHeight)")

        // Update scroll view height
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true

                scrollViewHeightConstraint.animator().constant = newScrollHeight
                containerView.layoutSubtreeIfNeeded()
            })
        } else {
            scrollViewHeightConstraint.constant = newScrollHeight
            containerView.layoutSubtreeIfNeeded()
        }

        // Update popover content size to trigger resize (height only, keep width fixed at 380)
        if let popover = appDelegate?.menuBarPopover {
            // Force layout to complete so fittingSize is accurate
            view.layoutSubtreeIfNeeded()
            containerView.layoutSubtreeIfNeeded()

            // Get the actual banner height (0 or 50 depending on visibility)
            let bannerHeight = welcomeBannerHeightConstraint?.constant ?? 0

            // Calculate new height based on all content sections with dynamic banner height
            let newHeight: CGFloat =
                24 + // Top padding
                10 + 8 + 22 + 20 + // Status dot + spacing + speaker name + spacing
                1 + 16 + // Divider + spacing
                13 + 8 + 22 + 16 + // Volume label + spacing + slider + spacing
                1 + 12 + // Divider + spacing
                13 + 12 + bannerHeight + 8 + // Speakers title + spacing + banner (dynamic) + spacing
                newScrollHeight + 12 + 30 + 16 + // Scroll view + spacing + buttons + spacing
                1 + 12 + // Divider + spacing
                13 + 4 + 12 + 12 + // Trigger title + spacing + value label + spacing
                1 + 16 + 44 + 16 + // Divider + spacing + actions + padding
                8 // Bottom padding

            let newSize = NSSize(width: 380, height: newHeight)

            // Update preferred content size to match
            self.preferredContentSize = newSize

            if animated {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = duration
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    popover.contentSize = newSize
                })
            } else {
                popover.contentSize = newSize
            }
        }
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

        // Discovery completed if we're calling refresh
        isLoadingDevices = false

        speakerNameLabel.stringValue = appDelegate?.settings.lastActiveSpeaker ?? "No Speaker"
        updateStatus()
        updateTriggerDeviceLabel()
        populateSpeakers()
        // Don't fetch volume here - it will be updated via notification after device selection
    }

    func updateTriggerDeviceLabel() {
        guard let settings = appDelegate?.settings else { return }
        let currentTrigger = settings.triggerDeviceName
        triggerDeviceLabel.stringValue = currentTrigger.isEmpty ? "Any Device" : currentTrigger
    }

    private func updateVolumeFromSonos() {
        // Update volume type label
        updateVolumeTypeLabel()

        Task { @MainActor in
            await appDelegate?.sonosController.getVolume { @Sendable [weak self] volume in
                DispatchQueue.main.async {
                    guard let self = self else { return }

                    self.applyGroupVolumeUpdate(volume, refreshMembers: false)
                }
            }
        }
    }

    // MARK: - Mouse Tracking for Checkbox Hover

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if let trackingArea = event.trackingArea,
           let checkbox = trackingArea.userInfo?["checkbox"] as? NSButton {
            checkbox.isHidden = false
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if let trackingArea = event.trackingArea,
           let checkbox = trackingArea.userInfo?["checkbox"] as? NSButton {
            // Keep checkbox visible if it's checked (selected for grouping/ungrouping)
            if checkbox.state != .on {
                checkbox.isHidden = true
            }
        }
    }
}
