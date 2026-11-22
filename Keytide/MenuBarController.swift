import Cocoa

/// Number formatting shared by the status item and its Settings preview.
enum MenuBarDisplayPreferences {
    static let fullNumbersKey = "menuBar.fullNumbers.v1"

    static func number(_ value: Int, full: Bool) -> String {
        if !full { return formatMenuBarCompactNumber(value) }
        return value.formatted(.number.grouping(.automatic))
    }
}

/// 菜单栏控制器
final class MenuBarController: NSObject, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private var statusView: MenuBarStatusView?
    private var replayStatusObserver: NSObjectProtocol?
    private var popover: NSPopover?
    private var popoverStyle: MenuUIStyle = .standard
    private var historySelections: [MenuUIStyle: MenuHistorySelection] = [:]
    private var eventMonitor: Any?
    private let menuBarUpdateInterval: TimeInterval = 0.1
    private var pendingMenuBarUpdate: DispatchWorkItem?
    private var lastMenuBarUpdateTime: TimeInterval = 0

    override init() {
        super.init()
        setupStatusItem()
        observeMenuBarStats()
    }

    private func observeMenuBarStats() {
        replayStatusObserver = NotificationCenter.default.addObserver(forName: .keyReplayRecordingChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateMenuBarAppearance()
        }
        StatsManager.shared.menuBarUpdateHandler = { [weak self] in
            self?.scheduleMenuBarUpdate()
        }
    }

    private func stopObservingMenuBarStats() {
        if let replayStatusObserver { NotificationCenter.default.removeObserver(replayStatusObserver) }
        replayStatusObserver = nil
        StatsManager.shared.menuBarUpdateHandler = nil
        pendingMenuBarUpdate?.cancel()
        pendingMenuBarUpdate = nil
    }

    deinit {
        stopObservingMenuBarStats()
        removeEventMonitor()
    }

    // MARK: - 设置状态栏项

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let statusView = MenuBarStatusView()
        statusView.onClick = { [weak self] in
            self?.togglePopover()
        }
        statusView.onRightClick = { [weak self] in
            self?.showContextMenu()
        }
        statusItem.view = statusView
        self.statusView = statusView
        updateMenuBarAppearance()
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let settingsItem = NSMenuItem(
            title: NSLocalizedString("settings.title", comment: ""),
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let mechanicalKeyboardItem = NSMenuItem(
            title: NSLocalizedString("keyboardVisualization.entry", comment: ""),
            action: #selector(openMechanicalKeyboard),
            keyEquivalent: ""
        )
        mechanicalKeyboardItem.target = self
        menu.addItem(mechanicalKeyboardItem)
        let recording = KeyReplayRecording.shared
        let recordingTitle = recording.isEnabled ? "replay.recording.stop" : "replay.recording.off"
        let recordingItem = NSMenuItem(title: NSLocalizedString(recordingTitle, comment: ""),
                                       action: #selector(stopReplayRecording), keyEquivalent: "")
        recordingItem.target = self
        recordingItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        recordingItem.isEnabled = recording.isEnabled && !recording.changing
        menu.addItem(recordingItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: NSLocalizedString("button.quit", comment: ""),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - 设置弹出面板

    private func setupPopover() {
        let popover = NSPopover()
        self.popover = popover
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = false
        popoverStyle = MenuUIStyle.current
        let controller: NSViewController & MenuStatsPresenting
        if popoverStyle == .geek { controller = GeekStatsPopoverViewController() }
        else { controller = StatsPopoverViewController() }
        controller.historySelection = historySelections[popoverStyle] ?? MenuHistorySelection()
        controller.preferredSizeDidChange = { [weak self, weak controller] targetSize in
            guard let popover = self?.popover, let controller, popover.contentViewController === controller else { return }
            popover.contentSize = targetSize
        }
        popover.contentViewController = controller
    }

    // MARK: - 设置事件监听（点击外部关闭弹窗）

    private func setupEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let popover = self?.popover, popover.isShown {
                popover.performClose(nil)
            }
        }
    }

    private func removeEventMonitor() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, popover === closed else { return }
        releasePopover(closed)
    }

    private func releasePopover(_ closed: NSPopover) {
        removeEventMonitor()
        if let controller = closed.contentViewController as? MenuStatsPresenting {
            historySelections[popoverStyle] = controller.historySelection
            controller.preferredSizeDidChange = nil
        }
        popover = nil
        StatsManager.shared.discardPresentationHistory()
    }

    // MARK: - 操作

    @objc private func togglePopover() {
        if popover?.isShown == true {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showContextMenu() {
        closePopover()
        statusItem.popUpMenu(makeContextMenu())
    }

    @objc private func stopReplayRecording() { KeyReplayRecording.shared.setEnabled(false) }

    @objc private func openSettings() {
        AppDelegate.trackClick("context_menu_settings")
        SettingsWindowController.shared.show()
    }

    @objc private func openMechanicalKeyboard() {
        AppDelegate.trackClick("context_menu_mechanical_keyboard")
        KeyboardHeatmapWindowController.shared.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func showStatistics() { showPopover() }

    private func showPopover() {
        if popover?.isShown == true { return }
        if let popover { releasePopover(popover) }
        setupPopover()
        guard let popover else { return }
        // 先激活应用，确保弹窗可以接收焦点
        NSApp.activate(ignoringOtherApps: true)

        if let statsPopoverViewController = popover.contentViewController as? MenuStatsPresenting {
            statsPopoverViewController.prepareForPopoverPresentation()
            popover.contentSize = statsPopoverViewController.preferredContentSize
        }

        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let view = statusItem.view {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else {
            releasePopover(popover)
            return
        }

        // 确保 popover 窗口成为 key window
        popover.contentViewController?.view.window?.makeKey()
        if popover.isShown { setupEventMonitor() }
        else { releasePopover(popover) }
        AppDelegate.trackClick("tray_icon")
        AppDelegate.trackPageView("stats_popup")
    }

    private func closePopover() {
        popover?.performClose(nil)
    }

    #if DEBUG
    func presentForGUIAcceptance() {
        guard AppLaunchMode.current == .guiAcceptance else { return }
        // The status item's window is attached after applicationDidFinishLaunching.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.showPopover()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let popover = self.popover else { return }
                NSLog("[GUI Acceptance] Statistics popover shown=\(popover.isShown) size=\(popover.contentSize) anchorVisible=\(self.statusItem?.view?.window?.isVisible ?? false)")
            }
        }
    }
    #endif

    private func scheduleMenuBarUpdate() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.scheduleMenuBarUpdate()
            }
            return
        }

        guard pendingMenuBarUpdate == nil else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastMenuBarUpdateTime
        guard elapsed < menuBarUpdateInterval else {
            performMenuBarUpdate()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingMenuBarUpdate = nil
            self.performMenuBarUpdate()
        }
        pendingMenuBarUpdate = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (menuBarUpdateInterval - elapsed),
            execute: workItem
        )
    }

    private func performMenuBarUpdate() {
        lastMenuBarUpdateTime = ProcessInfo.processInfo.systemUptime
        updateMenuBarAppearance()
    }

    // MARK: - 菜单栏显示样式

    private func updateMenuBarAppearance() {
        guard let statusItem, let statusView else { return }
        let manager = StatsManager.shared
        let stats = manager.displayCurrentStats()
        let defaults = UserDefaults.standard
        let full = defaults.bool(forKey: MenuBarDisplayPreferences.fullNumbersKey)
        statusView.update(.init(
            keysText: MenuBarDisplayPreferences.number(stats.keyPresses, full: full),
            clicksText: MenuBarDisplayPreferences.number(stats.totalClicks, full: full),
            fullNumbers: full
        ))

        let recording = KeyReplayRecording.shared
        let replay = recording.isEnabled ? " · " + NSLocalizedString(recording.statusKey, comment: "") : ""
        let summary = "\(NSLocalizedString("setting.showKeyPresses", comment: "")): \(stats.keyPresses.formatted()) · \(NSLocalizedString("setting.showMouseClicks", comment: "")): \(stats.totalClicks.formatted())" + replay
        if statusView.toolTip != summary {
            statusView.toolTip = summary
            statusView.setAccessibilityLabel(summary)
        }
        let width = statusView.intrinsicContentSize.width
        if statusItem.length != width { statusItem.length = width }
    }
}

// MARK: - 菜单栏自定义视图

final class MenuBarStatusView: NSView {
    struct Presentation: Equatable {
        var keysText: String
        var clicksText: String
        var fullNumbers: Bool
    }

    private static let horizontalInset: CGFloat = 3
    private static let keysFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    private static let clicksFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)

    private var presentation = Presentation(keysText: "", clicksText: "", fullNumbers: false)
    private var keys = NSAttributedString(string: "")
    private var clicks = NSAttributedString(string: "")
    private var keySize = NSSize.zero
    private var clickSize = NSSize.zero
    private var reservedTextWidth: CGFloat = 0

    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    func update(_ next: Presentation) {
        guard next != presentation else { return }
        let oldSize = intrinsicContentSize
        if next.fullNumbers != presentation.fullNumbers {
            reservedTextWidth = 0
        }
        if next.keysText != presentation.keysText {
            keys = Self.metric(next.keysText, font: Self.keysFont)
            keySize = keys.size()
        }
        if next.clicksText != presentation.clicksText {
            clicks = Self.metric(next.clicksText, font: Self.clicksFont)
            clickSize = clicks.size()
        }
        presentation = next
        // Reserve space as counts grow to avoid shifting neighboring status items.
        reservedTextWidth = max(reservedTextWidth, keySize.width, clickSize.width)
        if oldSize != intrinsicContentSize { invalidateIntrinsicContentSize() }
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(2 * Self.horizontalInset + reservedTextWidth), height: 22)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rightEdge = bounds.maxX - Self.horizontalInset
        let rowOffset: CGFloat = 5
        keys.draw(at: NSPoint(x: rightEdge - keySize.width, y: bounds.midY + rowOffset - keySize.height / 2))
        clicks.draw(at: NSPoint(x: rightEdge - clickSize.width, y: bounds.midY - rowOffset - clickSize.height / 2))
    }

    private static func metric(_ text: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onRightClick?() }
        else { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}
