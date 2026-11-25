import Cocoa

class MainWindowController: NSWindowController {
    override func windowDidLoad() {
        super.windowDidLoad()
        window?.contentViewController = MainWindowViewController()
        window?.title = "Keytide"
    }
}

extension NSWindow {
    /// Presents a standalone window that can be switched to from the Dock.
    func presentInDock() {
        AppWindowDockPresence.shared.track(self)
        NSApp.activate(ignoringOtherApps: true)
        if isMiniaturized { deminiaturize(nil) }
        makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class AppWindowDockPresence: NSObject {
    static let shared = AppWindowDockPresence()
    // Track until close so hiding or minimizing a window keeps the app switchable.
    private let windows = NSHashTable<NSWindow>.weakObjects()

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)
    }

    func track(_ window: NSWindow) {
        windows.add(window)
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, windows.contains(window) else { return }
        windows.remove(window)
        guard windows.allObjects.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.windows.allObjects.isEmpty else { return }
            guard NSApp.activationPolicy() == .regular else { return }
            NSApp.setActivationPolicy(.accessory)
        }
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
