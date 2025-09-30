import Cocoa

@MainActor
class VolumeHUD {
    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var volumeLabel: NSTextField?
    private var progressFillView: NSView?
    private var speakerLabel: NSTextField?

    static let shared = VolumeHUD()

    private init() {}

    func show(speaker: String, volume: Int) {
        // Cancel any existing timer
        dismissTimer?.invalidate()

        // If panel exists, update it; otherwise create new one
        if let existingPanel = panel, existingPanel.isVisible {
            updateContent(speaker: speaker, volume: volume)
        } else {
            createPanel(speaker: speaker, volume: volume)
        }

        // Show with fade-in animation
        panel?.alphaValue = 0
        panel?.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel?.animator().alphaValue = 1.0
        }

        // Auto-dismiss after 1.5 seconds
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.hide()
            }
        }
    }

    func showError(title: String, message: String) {
        // Cancel any existing timer
        dismissTimer?.invalidate()

        // Always create new panel for error (different layout)
        createErrorPanel(title: title, message: message)

        // Show with fade-in animation
        panel?.alphaValue = 0
        panel?.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel?.animator().alphaValue = 1.0
        }

        // Auto-dismiss after 2 seconds (slightly longer for error messages)
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.hide()
            }
        }
    }

    private func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.panel?.orderOut(nil)
            }
        })
    }

    private func createPanel(speaker: String, volume: Int) {
        // Panel dimensions - taller for better spacing
        let width: CGFloat = 280
        let height: CGFloat = 160

        // Center on screen
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.frame
        let x = (screenRect.width - width) / 2
        let y = (screenRect.height - height) / 2
        let rect = NSRect(x: x, y: y, width: width, height: height)

        // Create panel with HUD style
        panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        guard let panel = panel else { return }

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Create visual effect view for Liquid Glass effect
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 20

        // Create content container
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // Speaker icon (SF Symbol) - from bottom: 104pt
        let iconView = NSImageView(frame: NSRect(x: (width - 44) / 2, y: 104, width: 44, height: 44))
        if let speakerImage = NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: "Speaker") {
            iconView.image = speakerImage
            iconView.contentTintColor = .white
            iconView.imageScaling = .scaleProportionallyUpOrDown
        }
        contentView.addSubview(iconView)

        // Speaker name label - from bottom: 78pt
        let nameLabel = NSTextField(labelWithString: speaker)
        nameLabel.frame = NSRect(x: 20, y: 78, width: width - 40, height: 20)
        nameLabel.alignment = .center
        nameLabel.font = .systemFont(ofSize: 15, weight: .medium)
        nameLabel.textColor = .white
        contentView.addSubview(nameLabel)
        speakerLabel = nameLabel

        // Volume percentage label - from bottom: 38pt
        let volLabel = NSTextField(labelWithString: "\(volume)%")
        volLabel.frame = NSRect(x: 20, y: 38, width: width - 40, height: 30)
        volLabel.alignment = .center
        volLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        volLabel.textColor = .white
        contentView.addSubview(volLabel)
        volumeLabel = volLabel

        // Progress bar background - from bottom: 18pt
        let progressBg = NSView(frame: NSRect(x: 30, y: 18, width: width - 60, height: 8))
        progressBg.wantsLayer = true
        progressBg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
        progressBg.layer?.cornerRadius = 4
        contentView.addSubview(progressBg)

        // Progress bar fill - from bottom: 18pt
        let progressWidth = (width - 60) * CGFloat(volume) / 100.0
        let progressFill = NSView(frame: NSRect(x: 30, y: 18, width: progressWidth, height: 8))
        progressFill.wantsLayer = true
        progressFill.layer?.backgroundColor = NSColor.white.cgColor
        progressFill.layer?.cornerRadius = 4
        contentView.addSubview(progressFill)
        progressFillView = progressFill

        visualEffect.addSubview(contentView)
        panel.contentView = visualEffect
    }

    private func updateContent(speaker: String, volume: Int) {
        // Update speaker name
        speakerLabel?.stringValue = speaker

        // Update volume label
        volumeLabel?.stringValue = "\(volume)%"

        // Update progress bar with animation
        if let progressFill = progressFillView {
            let panelWidth: CGFloat = 280
            let newWidth = (panelWidth - 60) * CGFloat(volume) / 100.0

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                progressFill.animator().setFrameSize(NSSize(width: newWidth, height: 8))
            }
        }
    }

    private func createErrorPanel(title: String, message: String) {
        // Panel dimensions
        let width: CGFloat = 280
        let height: CGFloat = 160

        // Center on screen
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.frame
        let x = (screenRect.width - width) / 2
        let y = (screenRect.height - height) / 2
        let rect = NSRect(x: x, y: y, width: width, height: height)

        // Create panel with HUD style
        panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        guard let panel = panel else { return }

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Create visual effect view for Liquid Glass effect
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 20

        // Create content container
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // Warning icon (SF Symbol) - from bottom: 94pt
        let iconView = NSImageView(frame: NSRect(x: (width - 50) / 2, y: 94, width: 50, height: 50))
        if let warningImage = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning") {
            iconView.image = warningImage
            iconView.contentTintColor = NSColor.systemOrange
            iconView.imageScaling = .scaleProportionallyUpOrDown
        }
        contentView.addSubview(iconView)

        // Title label - from bottom: 68pt
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.frame = NSRect(x: 20, y: 68, width: width - 40, height: 20)
        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        contentView.addSubview(titleLabel)

        // Message label - from bottom: 24pt, taller to accommodate two lines
        let messageLabel = NSTextField(labelWithString: message)
        messageLabel.frame = NSRect(x: 20, y: 24, width: width - 40, height: 40)
        messageLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: 13, weight: .regular)
        messageLabel.textColor = .white
        messageLabel.maximumNumberOfLines = 2
        messageLabel.lineBreakMode = .byWordWrapping
        contentView.addSubview(messageLabel)

        visualEffect.addSubview(contentView)
        panel.contentView = visualEffect
    }
}