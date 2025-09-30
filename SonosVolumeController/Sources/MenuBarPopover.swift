import Cocoa

@available(macOS 26.0, *)
@MainActor
class MenuBarPopover: NSPopover, NSPopoverDelegate {
    private weak var appDelegate: AppDelegate?
    private var menuContentViewController: MenuBarContentViewController?

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
}