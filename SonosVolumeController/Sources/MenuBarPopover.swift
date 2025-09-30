import Cocoa

@available(macOS 26.0, *)
@MainActor
class MenuBarPopover: NSPopover {
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
        behavior = .transient  // Closes when clicking outside
        animates = true

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
}