import Cocoa

final class KeyboardHeatmapWindowController: ReclaimingWindowController {
    static let shared = KeyboardHeatmapWindowController()
    private var lastBrowsing: KeyboardVisualizationViewController.BrowsingState?

    private init() { super.init(window: nil) }

    override func makeWindow() -> NSWindow {
        let viewController = KeyboardVisualizationViewController(restoring: lastBrowsing)
        let window = NSWindow(contentViewController: viewController)
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let initialSize = NSSize(width: min(1200, available.width - 32), height: min(800, available.height - 56))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = NSLocalizedString("keyboardVisualization.title", comment: "")
        window.titleVisibility = .visible
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovableByWindowBackground = true
        window.backgroundColor = KeyboardStudioPalette(style: .standard).background
        window.setContentSize(initialSize)
        window.minSize = NSSize(width: 980, height: 660)
        return window
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func preservePresentation() {
        lastBrowsing = (contentViewController as? KeyboardVisualizationViewController)?.browsingState
    }

    func show(day: Date) {
        show()
        (contentViewController as? KeyboardVisualizationViewController)?.showDay(day)
    }

    func show() {
        let window = windowForPresentation()
        let wasVisible = window.isVisible
        let wasMiniaturized = window.isMiniaturized
        window.presentInDock()
        window.orderFrontRegardless()

        if let vc = contentViewController as? KeyboardVisualizationViewController {
            vc.refreshForPresentation(resetToToday: !wasVisible && !wasMiniaturized)
            if !vc.showsGrowth { AppDelegate.trackPageView("keyboard_heatmap") }
        }
    }

    func showExample() {
        show()
        (contentViewController as? KeyboardVisualizationViewController)?.showExample()
    }
}
