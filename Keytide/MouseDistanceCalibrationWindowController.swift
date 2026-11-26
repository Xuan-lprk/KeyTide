import Cocoa

final class MouseDistanceCalibrationWindowController: ReclaimingWindowController {
    static let shared = MouseDistanceCalibrationWindowController()

    private init() { super.init(window: nil) }

    override func makeWindow() -> NSWindow {
        let calibrationViewController = MouseDistanceCalibrationViewController()
        let window = NSWindow(contentViewController: calibrationViewController)
        window.styleMask = [.titled, .closable]
        window.title = NSLocalizedString("settings.mouseDistanceCalibration.windowTitle", comment: "")
        window.setContentSize(NSSize(width: 360, height: 240))
        return window
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func windowWillClose(_ notification: Notification) {
        (contentViewController as? MouseDistanceCalibrationViewController)?.cancelCalibration()
        super.windowWillClose(notification)
    }

    func show() {
        let window = windowForPresentation()
        (contentViewController as? MouseDistanceCalibrationViewController)?.prepareForDisplay()
        window.presentInDock()
        window.orderFrontRegardless()
        AppDelegate.trackPageView("mouse_calibration")
    }
}
