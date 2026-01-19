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
    private var refreshButton: NSButton!
    
    // Playback Controls
    private var playPauseButton: NSButton!
    private var previousButton: NSButton!
    private var nextButton: NSButton!
    private var currentTransportState: String?  // Track current playback state
    
    // Now Playing Display
    private var nowPlayingContainer: NSView!
    private var nowPlayingAlbumArt: NSImageView!
    private var nowPlayingTitle: NSTextField!
    private var nowPlayingArtist: NSTextField!
    private var nowPlayingHeightConstraint: NSLayoutConstraint!
    
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

    // Cache now-playing data to prevent flicker during card rebuilds
    private var nowPlayingCache: [String: (state: String?, sourceType: SonosController.AudioSourceType?, nowPlaying: SonosController.NowPlayingInfo?)] = [:]

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
        setupPlaybackControlsSection(in: contentView)
        setupNowPlayingSection(in: contentView)
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

        // Listen for transport state changes to update now playing in real-time
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTransportStateChanged(_:)),
            name: NSNotification.Name("SonosTransportStateDidChange"),
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

    @objc private func handleTransportStateChanged(_ notification: Notification) {
        // Update the specific card with new transport state and metadata
        guard let userInfo = notification.userInfo,
              let deviceUUID = userInfo["deviceUUID"] as? String,
              let state = userInfo["state"] as? String else {
            return
        }

        print("🎵 UI received transport state change: \(state) for device \(deviceUUID)")

        Task { @MainActor in
            // Check if this is the selected device
            let selectedUUID = appDelegate?.sonosController.cachedSelectedDevice?.uuid
            if deviceUUID == selectedUUID {
                // Update current transport state
                currentTransportState = state
                
                // Update play/pause button
                updatePlayPauseButton(isPlaying: state == "PLAYING")
                
                // Update control availability (in case source type changed)
                updatePlaybackControlsState()
                
                // Update now-playing display
                updateNowPlayingDisplay()
            }

            // Find the card for this device
            guard let cardIndex = speakerCardsContainer.arrangedSubviews.firstIndex(where: { view in
                view.identifier?.rawValue == deviceUUID
            }) else {
                print("⚠️ Card not found for device \(deviceUUID)")
                return
            }

            let card = speakerCardsContainer.arrangedSubviews[cardIndex]

            // Refresh the now playing info for this card
            Task {
                await self.refreshNowPlayingForCard(card)
            }
        }
    }

    /// Refresh now playing info for a specific card
    private func refreshNowPlayingForCard(_ card: NSView) async {
        guard let deviceUUID = card.identifier?.rawValue,
              let controller = appDelegate?.sonosController else {
            return
        }

        // Get the device
        let devices = controller.cachedDiscoveredDevices
        guard let device = devices.first(where: { $0.uuid == deviceUUID }) else {
            return
        }

        // Fetch fresh now playing info
        if let info = await controller.getAudioSourceInfo(for: device) {
            await MainActor.run {
                // Update the card with the fresh info
                updateCardWithNowPlaying(
                    uuid: deviceUUID,
                    state: info.state,
                    sourceType: info.sourceType,
                    nowPlaying: info.nowPlaying
                )
            }
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

        // Refresh button
        refreshButton = NSButton()
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        refreshButton.bezelStyle = .inline
        refreshButton.isBordered = false
        refreshButton.contentTintColor = .tertiaryLabelColor
        refreshButton.target = self
        refreshButton.action = #selector(refreshTopology)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.toolTip = "Refresh speaker topology"
        container.addSubview(refreshButton)

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

            // Refresh button (to the left of power button)
            refreshButton.trailingAnchor.constraint(equalTo: powerButton.leadingAnchor, constant: -4),
            refreshButton.centerYAnchor.constraint(equalTo: powerButton.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 40),
            refreshButton.heightAnchor.constraint(equalToConstant: 40),

            // Divider
            divider1.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            divider1.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            divider1.topAnchor.constraint(equalTo: speakerNameLabel.bottomAnchor, constant: 20),
            divider1.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    // MARK: - Playback Controls Section

    private func setupPlaybackControlsSection(in container: NSView) {
        // Container for playback controls (horizontally centered)
        let controlsContainer = NSView()
        controlsContainer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controlsContainer)

        // Previous button
        previousButton = createTransportButton(
            symbolName: "backward.fill",
            size: 28,
            action: #selector(previousTapped)
        )
        previousButton.toolTip = "Previous Track"
        controlsContainer.addSubview(previousButton)

        // Play/Pause button (larger, more prominent)
        playPauseButton = createTransportButton(
            symbolName: "play.fill",
            size: 32,
            action: #selector(playPauseTapped)
        )
        playPauseButton.toolTip = "Play"
        controlsContainer.addSubview(playPauseButton)

        // Next button
        nextButton = createTransportButton(
            symbolName: "forward.fill",
            size: 28,
            action: #selector(nextTapped)
        )
        nextButton.toolTip = "Next Track"
        controlsContainer.addSubview(nextButton)

        // Initially disable all controls until a device is selected
        previousButton.isEnabled = false
        playPauseButton.isEnabled = false
        nextButton.isEnabled = false

        // Divider after controls
        let divider = createDivider()
        container.addSubview(divider)

        // Find the previous divider to anchor to
        let previousDivider = container.subviews.compactMap { $0 as? NSBox }.first

        NSLayoutConstraint.activate([
            // Controls container - centered horizontally below header with more breathing room
            controlsContainer.topAnchor.constraint(equalTo: previousDivider!.bottomAnchor, constant: 20),
            controlsContainer.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            controlsContainer.heightAnchor.constraint(equalToConstant: 48),

            // Previous button
            previousButton.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor),
            previousButton.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: 48),
            previousButton.heightAnchor.constraint(equalToConstant: 48),

            // Play/Pause button (centered with spacing)
            playPauseButton.leadingAnchor.constraint(equalTo: previousButton.trailingAnchor, constant: 16),
            playPauseButton.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 48),
            playPauseButton.heightAnchor.constraint(equalToConstant: 48),

            // Next button
            nextButton.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 16),
            nextButton.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 48),
            nextButton.heightAnchor.constraint(equalToConstant: 48),
            nextButton.trailingAnchor.constraint(equalTo: controlsContainer.trailingAnchor),

            // Divider below controls with more space
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            divider.topAnchor.constraint(equalTo: controlsContainer.bottomAnchor, constant: 20),
            divider.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    /// Create a styled transport control button
    private func createTransportButton(symbolName: String, size: CGFloat, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        button.bezelStyle = .circular
        button.isBordered = true
        button.contentTintColor = .labelColor
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        
        // Style the button to look like macOS media controls
        button.wantsLayer = true
        button.layer?.cornerRadius = 24  // Match the new 48pt size
        
        return button
    }

    // MARK: - Now Playing Section

    private func setupNowPlayingSection(in container: NSView) {
        // Container for now playing info
        nowPlayingContainer = NSView()
        nowPlayingContainer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(nowPlayingContainer)
        
        // Album art thumbnail (44x44pt with corner radius)
        nowPlayingAlbumArt = NSImageView()
        nowPlayingAlbumArt.wantsLayer = true
        nowPlayingAlbumArt.layer?.cornerRadius = 6
        nowPlayingAlbumArt.layer?.masksToBounds = true
        nowPlayingAlbumArt.layer?.borderWidth = 0.5
        nowPlayingAlbumArt.layer?.borderColor = NSColor.separatorColor.cgColor
        nowPlayingAlbumArt.imageScaling = .scaleProportionallyUpOrDown
        nowPlayingAlbumArt.translatesAutoresizingMaskIntoConstraints = false
        nowPlayingContainer.addSubview(nowPlayingAlbumArt)
        
        // Text stack container
        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.spacing = 2
        textStack.alignment = .leading
        textStack.distribution = .fill
        textStack.translatesAutoresizingMaskIntoConstraints = false
        nowPlayingContainer.addSubview(textStack)
        
        // Track title label
        nowPlayingTitle = NSTextField(labelWithString: "")
        nowPlayingTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        nowPlayingTitle.textColor = .labelColor
        nowPlayingTitle.lineBreakMode = .byTruncatingTail
        nowPlayingTitle.maximumNumberOfLines = 1
        nowPlayingTitle.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(nowPlayingTitle)
        
        // Artist/metadata label
        nowPlayingArtist = NSTextField(labelWithString: "")
        nowPlayingArtist.font = .systemFont(ofSize: 11, weight: .regular)
        nowPlayingArtist.textColor = .secondaryLabelColor
        nowPlayingArtist.lineBreakMode = .byTruncatingTail
        nowPlayingArtist.maximumNumberOfLines = 1
        nowPlayingArtist.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(nowPlayingArtist)
        
        // Find the previous divider to anchor to (after playback controls)
        let allDividers = container.subviews.compactMap { $0 as? NSBox }
        let previousDivider = allDividers.count >= 2 ? allDividers[1] : allDividers.first
        
        // Create height constraint for show/hide functionality
        nowPlayingHeightConstraint = nowPlayingContainer.heightAnchor.constraint(equalToConstant: 0)
        nowPlayingHeightConstraint.priority = .required
        
        NSLayoutConstraint.activate([
            // Container positioning (between playback controls and volume)
            nowPlayingContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            nowPlayingContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            nowPlayingContainer.topAnchor.constraint(equalTo: previousDivider!.bottomAnchor, constant: 16),
            nowPlayingHeightConstraint,
            
            // Album art positioning and size
            nowPlayingAlbumArt.leadingAnchor.constraint(equalTo: nowPlayingContainer.leadingAnchor),
            nowPlayingAlbumArt.centerYAnchor.constraint(equalTo: nowPlayingContainer.centerYAnchor),
            nowPlayingAlbumArt.widthAnchor.constraint(equalToConstant: 44),
            nowPlayingAlbumArt.heightAnchor.constraint(equalToConstant: 44),
            
            // Text stack positioning
            textStack.leadingAnchor.constraint(equalTo: nowPlayingAlbumArt.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: nowPlayingContainer.trailingAnchor),
            textStack.centerYAnchor.constraint(equalTo: nowPlayingContainer.centerYAnchor),
        ])
        
        // Start hidden (will be shown when device is selected and playing)
        nowPlayingContainer.isHidden = true
    }
    
    /// Update the now-playing display with current track info
    @MainActor
    private func updateNowPlayingDisplay() {
        guard let controller = appDelegate?.sonosController,
              let selectedDevice = controller.cachedSelectedDevice else {
            // No device selected - hide now-playing
            hideNowPlayingSection()
            return
        }
        
        // Check cache first for this device's now-playing info
        let cache = nowPlayingCache[selectedDevice.uuid]
        let sourceType = cache?.sourceType ?? selectedDevice.audioSource
        let nowPlaying = cache?.nowPlaying ?? selectedDevice.nowPlaying
        let transportState = cache?.state ?? selectedDevice.transportState
        
        // Hide if idle or no source type
        guard let source = sourceType, source != .idle else {
            hideNowPlayingSection()
            return
        }
        
        // Update based on source type
        switch source {
        case .streaming:
            if let np = nowPlaying {
                showNowPlayingSection()
                nowPlayingTitle.stringValue = np.title ?? "Unknown Track"
                nowPlayingArtist.stringValue = np.artist ?? ""
                
                // Load album art
                if let artURL = np.albumArtURL {
                    loadAlbumArt(url: artURL, sourceType: source)
                } else {
                    setFallbackAlbumArt(sourceType: source)
                }
            } else {
                // Streaming but no metadata yet
                showNowPlayingSection()
                nowPlayingTitle.stringValue = transportState == "PLAYING" ? "Playing..." : "Ready"
                nowPlayingArtist.stringValue = ""
                setFallbackAlbumArt(sourceType: source)
            }
            
        case .radio:
            showNowPlayingSection()
            nowPlayingTitle.stringValue = nowPlaying?.title ?? "Radio"
            nowPlayingArtist.stringValue = nowPlaying?.artist ?? "Streaming"
            setFallbackAlbumArt(sourceType: source)
            
        case .lineIn:
            showNowPlayingSection()
            nowPlayingTitle.stringValue = "Line-In Audio"
            nowPlayingArtist.stringValue = selectedDevice.name
            setFallbackAlbumArt(sourceType: source)
            
        case .tv:
            showNowPlayingSection()
            nowPlayingTitle.stringValue = "TV Audio"
            nowPlayingArtist.stringValue = selectedDevice.name
            setFallbackAlbumArt(sourceType: source)
            
        case .grouped:
            // If grouped, show coordinator's now-playing info
            if let group = controller.cachedDiscoveredGroups.first(where: { $0.isMember(selectedDevice) }) {
                let coordinatorCache = nowPlayingCache[group.coordinator.uuid]
                if let coordSource = coordinatorCache?.sourceType, coordSource != SonosController.AudioSourceType.idle {
                    // Recursively update using coordinator's info (will handle source type appropriately)
                    // For now, just show grouped status
                    showNowPlayingSection()
                    nowPlayingTitle.stringValue = "Grouped Playback"
                    nowPlayingArtist.stringValue = "Following \(group.coordinator.name)"
                    setFallbackAlbumArt(sourceType: .grouped)
                } else {
                    hideNowPlayingSection()
                }
            } else {
                hideNowPlayingSection()
            }
            
        case .idle:
            hideNowPlayingSection()
        }
    }
    
    private func showNowPlayingSection() {
        nowPlayingContainer.isHidden = false
        nowPlayingHeightConstraint.constant = 60  // Album art (44pt) + padding
        updatePopoverSize(animated: true, duration: 0.2)
    }
    
    private func hideNowPlayingSection() {
        nowPlayingContainer.isHidden = true
        nowPlayingHeightConstraint.constant = 0
        updatePopoverSize(animated: true, duration: 0.2)
    }
    
    private func loadAlbumArt(url: String, sourceType: SonosController.AudioSourceType) {
        guard let controller = appDelegate?.sonosController else { return }
        
        // Set fallback first
        setFallbackAlbumArt(sourceType: sourceType)
        
        // Then load actual art async
        Task {
            if let albumArt = await controller.fetchAlbumArt(url: url) {
                await MainActor.run {
                    nowPlayingAlbumArt.image = albumArt
                }
            }
        }
    }
    
    private func setFallbackAlbumArt(sourceType: SonosController.AudioSourceType) {
        let symbolName: String
        let backgroundColor: NSColor
        
        switch sourceType {
        case .streaming:
            symbolName = "music.note"
            backgroundColor = .systemGreen.withAlphaComponent(0.2)
        case .radio:
            symbolName = "antenna.radiowaves.left.and.right"
            backgroundColor = .systemTeal.withAlphaComponent(0.2)
        case .lineIn:
            symbolName = "waveform"
            backgroundColor = .systemBlue.withAlphaComponent(0.2)
        case .tv:
            symbolName = "tv"
            backgroundColor = .systemPurple.withAlphaComponent(0.2)
        case .grouped:
            symbolName = "hifispeaker.2"
            backgroundColor = .systemGray.withAlphaComponent(0.2)
        case .idle:
            symbolName = "music.note"
            backgroundColor = .systemGray.withAlphaComponent(0.2)
        }
        
        // Create image with symbol and background
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        guard let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) else { return }
        
        let fallbackImage = NSImage(size: NSSize(width: 44, height: 44))
        fallbackImage.lockFocus()
        
        // Background
        backgroundColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 44, height: 44), xRadius: 6, yRadius: 6).fill()
        
        // Center the symbol
        let symbolSize = symbolImage.size
        let x = (44 - symbolSize.width) / 2
        let y = (44 - symbolSize.height) / 2
        symbolImage.draw(at: NSPoint(x: x, y: y), from: .zero, operation: .sourceOver, fraction: 1.0)
        
        fallbackImage.unlockFocus()
        nowPlayingAlbumArt.image = fallbackImage
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

        NSLayoutConstraint.activate([
            volumeTypeLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            volumeTypeLabel.topAnchor.constraint(equalTo: nowPlayingContainer.bottomAnchor, constant: 16),

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
        // Start with a reasonable default, will be updated dynamically based on content and screen size
        scrollViewHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 200)
        scrollViewHeightConstraint.priority = .defaultHigh  // Allow it to be overridden
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
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.toolTip = group.name  // Show full name on hover
        nameLabel.identifier = NSUserInterfaceItemIdentifier("groupNameLabel")  // For repositioning when album art added
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
        // Keep group checkboxes visible to avoid hover/tap ambiguity
        checkbox.isHidden = false

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

        card.addSubview(icon)
        card.addSubview(nameLabel)
        card.addSubview(checkbox)

        // Set up constraints - nameLabel positioned directly after icon (no album art)
        NSLayoutConstraint.activate([
            // Position icon at leading edge
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            // Position name after icon: 8 (leading) + 20 (icon width) + 10 (spacing) = 38pt
            nameLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 38),
            nameLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: checkbox.leadingAnchor, constant: -10),

            // Checkbox stays on right (aligned with speaker checkboxes)
            checkbox.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            checkbox.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 50)
        ])
        
        // Add source badge if available (no album art in cards)
        if let cached = nowPlayingCache[group.coordinator.uuid],
           let sourceType = cached.sourceType {
            addSourceBadge(to: card, sourceType: sourceType)
        }

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
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.toolTip = device.name  // Show full name on hover
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
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.toolTip = device.name  // Show full name on hover
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

        card.addSubview(icon)
        card.addSubview(textStack)
        card.addSubview(checkbox)

        // Add source badge if available (no album art in cards)
        if let cached = nowPlayingCache[device.uuid],
           let sourceType = cached.sourceType {
            addSourceBadge(to: card, sourceType: sourceType)
        }

        NSLayoutConstraint.activate([
            // Icon at leading edge
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
            
            // Update now-playing display for selected device
            self.updateNowPlayingDisplay()
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
        // Update cache first
        nowPlayingCache[uuid] = (state, sourceType, nowPlaying)

        // Find the card by UUID (stored in identifier)
        for subview in speakerCardsContainer.arrangedSubviews {
            if subview.identifier?.rawValue == uuid {
                // Add colored badge only (no album art in cards)
                if let sourceType = sourceType {
                    addSourceBadge(to: subview, sourceType: sourceType)
                }
                break
            }
        }
    }

    /// Add colored source badge to card
    private func addSourceBadge(to card: NSView, sourceType: SonosController.AudioSourceType) {
        // Set badge color based on source type
        let badgeColor: NSColor
        switch sourceType {
        case .streaming:
            badgeColor = .systemGreen
        case .radio:
            badgeColor = .systemTeal
        case .lineIn, .tv:
            badgeColor = .systemBlue
        case .grouped:
            badgeColor = NSColor.systemYellow.withAlphaComponent(0.8)
        case .idle:
            badgeColor = .tertiaryLabelColor
        }
        
        // Check if badge already exists - if so, just update the color
        if let existingBadge = card.subviews.first(where: { $0.identifier?.rawValue == "sourceBadge" }) {
            existingBadge.layer?.backgroundColor = badgeColor.cgColor
            return
        }
        
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.identifier = NSUserInterfaceItemIdentifier("sourceBadge")
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

    @objc private func refreshTopology() {
        print("🔄 User requested topology refresh")

        // Show loading state
        isLoadingDevices = true
        populateSpeakers()

        // Trigger discovery with topology refresh
        Task {
            guard let controller = appDelegate?.sonosController else { return }
            await controller.discoverDevices(forceRefreshTopology: true) { [weak self] in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        }
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        let volume = Int(sender.doubleValue)
        volumeLabel.stringValue = "\(volume)%"

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
            await appDelegate?.sonosController.setVolume(volume)

            // After setting group volume, refresh all member volumes
            // (Sonos adjusts member volumes proportionally)
            await MainActor.run {
                self.refreshMemberVolumes()
                self.scheduleGroupVolumeAdjustmentReset()
            }
        }
    }

    @objc private func volumeDidChange(_ notification: Notification) {
        // Update slider when volume changes via hotkeys or initial load
        guard let userInfo = notification.userInfo,
              let volume = userInfo["volume"] as? Int else { return }

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

    // MARK: - Playback Control Actions

    @objc private func playPauseTapped() {
        guard let controller = appDelegate?.sonosController else {
            print("⚠️ Play/Pause tapped but no controller available")
            return
        }

        print("🎵 Play/Pause button tapped - current state: \(currentTransportState ?? "nil")")
        
        // Toggle between play and pause based on current state
        if currentTransportState == "PLAYING" {
            print("▶️ Sending pause command")
            Task {
                await controller.pauseSelected()
            }
            // Optimistically update UI
            updatePlayPauseButton(isPlaying: false)
        } else {
            print("⏸️ Sending play command")
            Task {
                await controller.playSelected()
            }
            // Optimistically update UI
            updatePlayPauseButton(isPlaying: true)
        }
    }

    @objc private func nextTapped() {
        guard let controller = appDelegate?.sonosController else { return }
        Task {
            await controller.nextTrack()
        }
    }

    @objc private func previousTapped() {
        guard let controller = appDelegate?.sonosController else { return }
        Task {
            await controller.previousTrack()
        }
    }

    /// Update play/pause button icon based on playback state
    private func updatePlayPauseButton(isPlaying: Bool) {
        let symbolName = isPlaying ? "pause.fill" : "play.fill"
        let tooltip = isPlaying ? "Pause" : "Play"
        
        playPauseButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )
        playPauseButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 32,
            weight: .medium
        )
        playPauseButton.toolTip = tooltip
    }

    /// Update the state of all playback controls based on current device and transport state
    private func updatePlaybackControlsState() {
        guard let controller = appDelegate?.sonosController else {
            // No controller - disable everything
            print("🎵 Disabling playback controls - no controller")
            playPauseButton.isEnabled = false
            previousButton.isEnabled = false
            nextButton.isEnabled = false
            return
        }

        let (canControl, supportsSkipping) = controller.getTransportCapabilities()
        
        print("🎵 Updating playback controls: canControl=\(canControl), supportsSkipping=\(supportsSkipping)")

        // Update button enabled states
        playPauseButton.isEnabled = canControl
        previousButton.isEnabled = canControl && supportsSkipping
        nextButton.isEnabled = canControl && supportsSkipping

        // Update tooltips for disabled skip buttons
        if !supportsSkipping && canControl {
            previousButton.toolTip = "Not available for this source"
            nextButton.toolTip = "Not available for this source"
        } else {
            previousButton.toolTip = "Previous Track"
            nextButton.toolTip = "Next Track"
        }
    }

    private func performMemberVolumeRefresh() {
        // Find all member card containers (paddedContainer wrapping the actual member card)
        let memberContainers = speakerCardsContainer.arrangedSubviews.filter { view in
            guard let identifier = view.identifier?.rawValue else { return false }
            return identifier.contains("_member_")
        }

        #if DEBUG
        print("📊 [UI] Refreshing \(memberContainers.count) member speaker volumes...")
        #endif

        for paddedContainer in memberContainers {
            // Navigate: paddedContainer -> memberCard -> find slider
            guard let memberCard = paddedContainer.subviews.first else { continue }

            // Find the volume slider in the actual member card
            if let volumeSlider = memberCard.subviews.compactMap({ $0 as? NSSlider }).first,
               let deviceUUID = volumeSlider.identifier?.rawValue,
               let device = appDelegate?.sonosController.cachedDiscoveredDevices.first(where: { $0.uuid == deviceUUID }) {

                // Refresh this speaker's individual volume
                // Capture container reference for later use
                let containerRef = paddedContainer
                Task { @MainActor in
                    await appDelegate?.sonosController.getIndividualVolume(device: device) { @Sendable volume in
                        guard let vol = volume else { return }

                        Task { @MainActor [weak containerRef] in
                            guard let container = containerRef else { return }

                            // Re-find the slider to ensure it still exists
                            guard let currentCard = container.subviews.first,
                                  let currentSlider = currentCard.subviews.compactMap({ $0 as? NSSlider }).first else {
                                return
                            }

                            #if DEBUG
                            print("📊 [UI] Updating \(device.name) slider: \(Int(currentSlider.doubleValue))% → \(vol)%")
                            #endif

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
        if let hitView = card.hitTest(clickLocation) {
            var view: NSView? = hitView
            while let current = view {
                if current is NSButton {
                    // Don't start gesture - let the button handle it
                    return false
                }
                view = current.superview
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

            // Subscribe to transport state updates for this device
            if let controller = appDelegate?.sonosController,
               let device = controller.cachedDiscoveredDevices.first(where: { $0.name == deviceName }) {
                await controller.subscribeToTransportUpdates(for: device.uuid)
                
                // Fetch audio source info to populate the device's audioSource field
                if let sourceInfo = await controller.getAudioSourceInfo(for: device) {
                    await MainActor.run {
                        self.currentTransportState = sourceInfo.state
                        self.updatePlayPauseButton(isPlaying: sourceInfo.state == "PLAYING")
                        // Trigger update after we have source info
                        self.updatePlaybackControlsState()
                        self.updateNowPlayingDisplay()
                    }
                } else {
                    // Fallback: use cached transport state if available
                    await MainActor.run {
                        self.currentTransportState = device.transportState
                        self.updatePlayPauseButton(isPlaying: device.transportState == "PLAYING")
                        self.updatePlaybackControlsState()
                        self.updateNowPlayingDisplay()
                    }
                }
            }
        }
        // Track this speaker as last active
        appDelegate?.settings.trackSpeakerActivity(deviceName)

        speakerNameLabel.stringValue = deviceName
        // Note: populateSpeakers() removed - cache prevents flicker during rebuilds
        // Rebuild will still happen on discovery/grouping, but with cached data

        // Update volume slider for the newly selected speaker
        updateVolumeFromSonos()
        
        // Update playback controls state
        updatePlaybackControlsState()
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
                
                // Get initial transport state for this group coordinator
                await MainActor.run {
                    self.currentTransportState = group.coordinator.transportState
                    self.updatePlayPauseButton(isPlaying: group.coordinator.transportState == "PLAYING")
                    self.updatePlaybackControlsState()
                    self.updateNowPlayingDisplay()
                }
            }
            // Track this group as last active
            appDelegate?.settings.trackSpeakerActivity(group.coordinator.name)

            // Update UI to show group name
            speakerNameLabel.stringValue = group.name
            // Note: populateSpeakers() removed - cache prevents flicker during rebuilds

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
        groupButton.title = "Analyzing..."
        groupProgressIndicator.startAnimation(nil)

        // Analyze devices to determine coordinator selection
        Task {
            let selection = await controller.analyzeCoordinatorSelection(from: selectedDevices)
            
            await MainActor.run {
                if selection.requiresUserChoice {
                    // Multiple devices playing - show dialog with now-playing info
                    print("🤔 Multiple devices playing - asking user to choose")
                    self.showEnhancedCoordinatorSelectionDialog(
                        playingDevices: selection.playingDevices,
                        allDevices: selectedDevices
                    )
                } else {
                    // Automatic selection (0-1 devices playing)
                    print("✅ Automatic coordinator selection: \(selection.suggestedCoordinator.name)")
                    self.groupButton.title = "Grouping..."
                    self.performGrouping(devices: selectedDevices, coordinator: selection.suggestedCoordinator)
                }
            }
        }
    }

    // Legacy dialog kept for reference - replaced by showEnhancedCoordinatorSelectionDialog
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
    
    /// Enhanced coordinator selection dialog with now-playing information
    private func showEnhancedCoordinatorSelectionDialog(playingDevices: [SonosController.SonosDevice], allDevices: [SonosController.SonosDevice]) {
        guard let controller = appDelegate?.sonosController else { return }
        
        // Fetch now-playing info for each device
        Task {
            let deviceInfos = await withTaskGroup(of: (String, SonosController.NowPlayingInfo?, SonosController.AudioSourceType).self) { group in
                for device in playingDevices {
                    group.addTask {
                        if let info = await controller.getAudioSourceInfo(for: device) {
                            return (device.uuid, info.nowPlaying, info.sourceType)
                        }
                        return (device.uuid, nil, .idle)
                    }
                }
                
                var results: [String: (nowPlaying: SonosController.NowPlayingInfo?, sourceType: SonosController.AudioSourceType)] = [:]
                for await (uuid, nowPlaying, sourceType) in group {
                    results[uuid] = (nowPlaying: nowPlaying, sourceType: sourceType)
                }
                return results
            }
            
            // Build the dialog on the main thread
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "Which Audio Should the Group Play?"
                
                // Build informative text with device details
                var infoLines: [String] = ["Multiple speakers are playing audio:\n"]
                
                for device in playingDevices {
                    let info = deviceInfos[device.uuid]
                    let sourceType = info?.sourceType ?? .idle
                    
                    // Device name with emoji
                    infoLines.append("🔊 \(device.name)")
                    
                    // Now-playing details based on source type
                    if let nowPlaying = info?.nowPlaying {
                        // Streaming or radio with track info
                        infoLines.append("   Playing: \(nowPlaying.displayText)")
                        if let album = nowPlaying.album, !album.isEmpty {
                            infoLines.append("   Album: \(album)")
                        }
                    } else {
                        // Non-streaming source (line-in, TV, etc.)
                        switch sourceType {
                        case .lineIn:
                            infoLines.append("   Source: Line-In Audio")
                        case .tv:
                            infoLines.append("   Source: TV/Home Theater")
                        case .radio:
                            infoLines.append("   Source: Radio Station")
                        case .streaming:
                            infoLines.append("   Source: Streaming Audio")
                        default:
                            infoLines.append("   Source: \(sourceType.description)")
                        }
                    }
                    infoLines.append("") // Blank line between devices
                }

                let hasLineIn = playingDevices.contains { deviceInfos[$0.uuid]?.sourceType == .lineIn }
                if hasLineIn {
                    infoLines.append("⚠️ Line-In will take over the group and stop other audio sources.")
                    infoLines.append("")
                }
                
                infoLines.append("Other speakers will sync to the selected audio source.")
                alert.informativeText = infoLines.joined(separator: "\n")
                alert.alertStyle = .informational
                
                // Add buttons with clear action text
                for device in playingDevices {
                    alert.addButton(withTitle: "Continue with \(device.name)")
                }
                alert.addButton(withTitle: "Cancel")
                
                let response = alert.runModal()
                
                // Map response to device selection
                if response.rawValue >= NSApplication.ModalResponse.alertFirstButtonReturn.rawValue,
                   response.rawValue < NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + playingDevices.count {
                    let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                    let chosenCoordinator = playingDevices[index]
                    print("✅ User chose coordinator: \(chosenCoordinator.name)")
                    self.groupButton.title = "Grouping..."
                    self.performGrouping(devices: allDevices, coordinator: chosenCoordinator)
                } else {
                    // User cancelled
                    print("❌ User cancelled grouping")
                    self.groupProgressIndicator.stopAnimation(nil)
                    self.groupButton.isEnabled = true
                    self.groupButton.title = "Group \(self.selectedSpeakerCards.count) Speakers"
                }
            }
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
        #if DEBUG
        print("🔍 [CALC] calculateContentHeight() called")
        #endif

        // Force layout to ensure all card frames are calculated
        speakerCardsContainer.layoutSubtreeIfNeeded()

        // Calculate total height of speaker cards
        var cardsHeight: CGFloat = 0
        for (_, view) in speakerCardsContainer.arrangedSubviews.enumerated() {
            cardsHeight += view.frame.height
        }

        // Add spacing between cards (8pt per gap)
        if speakerCardsContainer.arrangedSubviews.count > 1 {
            let spacing = CGFloat(speakerCardsContainer.arrangedSubviews.count - 1) * 8
            cardsHeight += spacing
        }

        // Add bottom padding
        cardsHeight += 8
        #if DEBUG
        print("🔍 [CALC] Final content height: \(cardsHeight)pt (cards: \(speakerCardsContainer.arrangedSubviews.count))")
        #endif

        return cardsHeight
    }

    private func updatePopoverSize(animated: Bool = true, duration: TimeInterval = 0.25) {
        // Guard against being called before view is loaded
        guard scrollViewHeightConstraint != nil else {
            print("⚠️ updatePopoverSize called before view loaded, skipping")
            return
        }

        let contentHeight = calculateContentHeight()
        
        // Calculate max scroll height based on screen size
        // Reserve space for menu bar, popover margins, and other sections
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        let otherSectionsHeight: CGFloat = 450  // Approximate height of non-scrollable sections
        let maxScrollHeight = max(200, screenHeight - otherSectionsHeight)  // At least 200pt, typically 450-700pt
        
        let newScrollHeight = min(contentHeight, maxScrollHeight)

        #if DEBUG
        print("🔍 [RESIZE] updatePopoverSize(animated: \(animated), duration: \(duration))")
        print("🔍 [RESIZE] Content height: \(contentHeight), scroll height: \(newScrollHeight)")
        #endif

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
            let nowPlayingHeight = nowPlayingHeightConstraint?.constant ?? 0

            // Calculate new height based on all content sections with dynamic heights
            let newHeight: CGFloat =
                24 + // Top padding
                10 + 8 + 22 + 20 + // Status dot + spacing + speaker name + spacing
                1 + 20 + // Divider + spacing (after header)
                48 + 20 + // Playback controls + spacing
                1 + 16 + // Divider + spacing (after playback controls)
                nowPlayingHeight + (nowPlayingHeight > 0 ? 16 : 0) + // Now playing section + spacing (when visible)
                13 + 8 + 22 + 16 + // Volume label + spacing + slider + spacing
                1 + 12 + // Divider + spacing (after volume)
                13 + 12 + bannerHeight + 8 + // Speakers title + spacing + banner (dynamic) + spacing
                newScrollHeight + 12 + 30 + 16 + // Scroll view + spacing + buttons + spacing
                1 + 12 + // Divider + spacing (after speakers)
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
        
        // Update playback controls state when refreshing
        updatePlaybackControlsState()
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
