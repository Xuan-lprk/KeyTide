import Cocoa

class MainWindowController: NSWindowController {
    override func windowDidLoad() {
        super.windowDidLoad()
        window?.contentViewController = MainWindowViewController()
        window?.title = "Keytide"
    }
}

/// Keeps the window entry point available while releasing AppKit content on close.
class ReclaimingWindowController: NSWindowController, NSWindowDelegate {
    private var lastFrame: NSRect?
    private weak var closingWindow: NSWindow?

    final func windowForPresentation() -> NSWindow {
        if let window { return window }
        let window = makeWindow()
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let lastFrame { window.setFrame(lastFrame, display: false) }
        else { window.center() }
        self.window = window
        return window
    }

    func makeWindow() -> NSWindow { preconditionFailure("Subclasses provide their own window") }
    func preservePresentation() {}
    var canReleaseWindow: Bool { true }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        closingWindow = window
        DispatchQueue.main.async { [weak self] in self?.releaseClosedWindow() }
    }

    final func releaseClosedWindow() {
        guard let closingWindow, !closingWindow.isVisible, window === closingWindow else { return }
        StatsManager.shared.discardPresentationHistory()
        guard canReleaseWindow else { return }
        preservePresentation()
        lastFrame = closingWindow.frame
        self.closingWindow = nil
        contentViewController = nil
        closingWindow.contentViewController = nil
        window = nil
    }
}
