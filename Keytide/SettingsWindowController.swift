import Cocoa

final class SettingsWindowController: ReclaimingWindowController {
    static let shared = SettingsWindowController()
    private var lastPage = SettingsPage.general

    private init() { super.init(window: nil) }

    override func makeWindow() -> NSWindow {
        let viewController = SettingsViewController(page: lastPage)
        let window = NSWindow(contentViewController: viewController)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.title = NSLocalizedString("settings.windowTitle", comment: "")
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.setContentSize(NSSize(width: 840, height: 650))
        window.contentMinSize = NSSize(width: 800, height: 600)
        return window
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func windowWillClose(_ notification: Notification) {
        (contentViewController as? SettingsViewController)?.commitThresholds()
        super.windowWillClose(notification)
    }

    override func preservePresentation() {
        lastPage = (contentViewController as? SettingsViewController)?.selectedPage ?? .general
    }

    override var canReleaseWindow: Bool {
        (contentViewController as? SettingsViewController)?.fileTransferInProgress != true
    }

    func show(page: SettingsPage? = nil) {
        let window = windowForPresentation()
        if let page { (window.contentViewController as? SettingsViewController)?.selectPage(page) }
        window.presentInDock()
        window.orderFrontRegardless()
        AppDelegate.trackPageView("settings")
    }
}
