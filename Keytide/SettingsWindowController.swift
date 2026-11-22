import Cocoa

final class SettingsWindowController: ReclaimingWindowController {
    static let shared = SettingsWindowController()
    private var lastPage = 0

    private init() { super.init(window: nil) }

    override func makeWindow() -> NSWindow {
        let viewController = SettingsViewController()
        viewController.restorePage(lastPage)
        let window = NSWindow(contentViewController: viewController)
        window.styleMask = [.titled, .closable]
        window.title = NSLocalizedString("settings.windowTitle", comment: "")
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.resizable)
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.setContentSize(NSSize(width: 840, height: 650))
        window.contentMinSize = NSSize(width: 800, height: 600)
        return window
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func preservePresentation() {
        lastPage = (contentViewController as? SettingsViewController)?.selectedPage ?? 0
    }

    override var canReleaseWindow: Bool {
        (contentViewController as? SettingsViewController)?.fileTransferInProgress != true
    }

    func show() {
        let window = windowForPresentation()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        AppDelegate.trackPageView("settings")
    }
}
