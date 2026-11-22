import Cocoa

final class AppStatsWindowController: ReclaimingWindowController {
    static let shared = AppStatsWindowController()
    private var lastBrowser: AppStatsViewController.BrowserState?

    private init() { super.init(window: nil) }

    override func makeWindow() -> NSWindow {
        let viewController = AppStatsViewController()
        viewController.restoreBrowser(lastBrowser)
        let window = NSWindow(contentViewController: viewController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = NSLocalizedString("appStats.windowTitle", comment: "")
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.setContentSize(NSSize(width: 760, height: 680))
        window.minSize = NSSize(width: 660, height: 520)
        return window
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func preservePresentation() {
        lastBrowser = (contentViewController as? AppStatsViewController)?.browserState()
    }

    func show() {
        let window = windowForPresentation()
        let wasVisible = window.isVisible
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        AppDelegate.trackPageView("app_stats")

        if wasVisible, let vc = contentViewController as? AppStatsViewController {
            vc.refreshData()
        }
    }
}
