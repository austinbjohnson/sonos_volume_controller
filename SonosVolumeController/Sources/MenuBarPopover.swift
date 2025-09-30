import Cocoa

@available(macOS 26.0, *)
@MainActor
class MenuBarPopover: NSPopover, NSPopoverDelegate {
    private weak var appDelegate: AppDelegate?
    private var menuContentViewController: MenuBarContentViewController?
    private var eventMonitor: Any?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()

        setupPopover()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupPopover() {
        // Configure popover behavior
        // Use .semitransient instead of .transient for more reliable auto-close
        // .semitransient closes when app loses focus or user interacts elsewhere
        behavior = .semitransient
        animates = true

        // Set delegate to handle close events
        self.delegate = self

        // Create content view controller
        menuContentViewController = MenuBarContentViewController(appDelegate: appDelegate)
        self.contentViewController = menuContentViewController
    }

    func toggle(from button: NSStatusBarButton) {
        if isShown {
            close()
        } else {
            show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func refresh() {
        menuContentViewController?.refresh()
    }

    // MARK: - NSPopoverDelegate

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        // Allow popover to close when clicking outside
        return true
    }

    func popoverDidShow(_ notification: Notification) {
        // Start monitoring for clicks outside the popover
        startMonitoring()
    }

    func popoverDidClose(_ notification: Notification) {
        // Stop monitoring when popover closes
        stopMonitoring()
    }

    // MARK: - Event Monitoring

    private func startMonitoring() {
        // Monitor for clicks outside the popover using global event monitor
        // Global monitor is required for .accessory apps that don't gain focus
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.close()
        }
    }

    private func stopMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}