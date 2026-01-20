import Cocoa

@available(macOS 26.0, *)
@MainActor
final class MenuBarMenu: NSObject, NSMenuDelegate {
    private let menu: NSMenu
    private let menuItem: NSMenuItem
    private let menuContentViewController: MenuBarContentViewController

    init(appDelegate: AppDelegate) {
        self.menu = NSMenu()
        self.menuItem = NSMenuItem()
        self.menuContentViewController = MenuBarContentViewController(appDelegate: appDelegate)

        super.init()

        menu.autoenablesItems = false
        menu.delegate = self
        menu.minimumWidth = MenuBarLayout.menuWidth

        menuItem.view = menuContentViewController.view
        menu.addItem(menuItem)

        updateLayout()
    }

    func attach(to statusItem: NSStatusItem) {
        statusItem.menu = menu
    }

    func show(from statusItem: NSStatusItem) {
        updateLayout()
        statusItem.popUpMenu(menu)
    }

    func refresh() {
        menuContentViewController.refresh()
        updateLayout()
    }

    func updateLayout() {
        let view = menuContentViewController.view
        view.layoutSubtreeIfNeeded()

        let preferredHeight = menuContentViewController.preferredContentSize.height
        let fittingHeight = view.fittingSize.height
        let targetHeight = max(preferredHeight, fittingHeight, 200)

        view.frame = NSRect(x: 0, y: 0, width: MenuBarLayout.menuWidth, height: targetHeight)
        menuItem.view = view
        menu.minimumWidth = MenuBarLayout.menuWidth
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuContentViewController.updateTriggerDeviceLabel()
        refresh()
    }
}
