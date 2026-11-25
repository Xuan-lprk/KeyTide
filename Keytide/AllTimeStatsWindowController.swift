import Cocoa

final class AllTimeStatsWindowController: ReclaimingWindowController {
    static let shared = AllTimeStatsWindowController()
    private var lastBrowsing: AllTimeStatsViewController.BrowsingState?

    private init() { super.init(window: nil) }

    override func makeWindow() -> NSWindow {
        let viewController = AllTimeStatsViewController()
        viewController.restoreBrowsing(lastBrowsing)
        let window = NSWindow(contentViewController: viewController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = NSLocalizedString("allTimeStats.windowTitle", comment: "")
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.setContentSize(NSSize(width: 900, height: 740))
        window.minSize = NSSize(width: 760, height: 640)
        return window
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func preservePresentation() {
        lastBrowsing = (contentViewController as? AllTimeStatsViewController)?.browsingState()
    }

    func show() {
        let window = windowForPresentation()
        window.presentInDock()
        window.orderFrontRegardless()
        AppDelegate.trackPageView("all_time_stats")

        if let vc = contentViewController as? AllTimeStatsViewController {
            vc.refreshData()
            DispatchQueue.main.async {
                vc.scrollToTop()
            }
        }
    }
}
