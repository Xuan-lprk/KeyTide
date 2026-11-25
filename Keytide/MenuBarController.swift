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
    private var widgetsPanel: MenuWidgetsPanel?
    private var classicPopover: NSPopover?
    private var classicStyle: MenuUIStyle = .standard
    private var classicHistorySelections: [MenuUIStyle: MenuHistorySelection] = [:]
    private var constellationHistory: MenuWidgetsPanel.ConstellationHistory = [:]
    private var pendingGeminiPreview: UUID?
    private var eventMonitor: Any?
    private var localEventMonitor: Any?
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
            self?.toggleStatistics()
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

        let monitoring = MonitoringStatus.shared
        if monitoring.state != .monitoring {
            let key = monitoring.failureDescription == nil ? "button.permission" : "monitoring.retry"
            let permissionItem = NSMenuItem(title: NSLocalizedString(key, comment: ""),
                                            action: #selector(requestMonitoring), keyEquivalent: "")
            permissionItem.target = self
            permissionItem.isEnabled = monitoring.state != .starting
            permissionItem.toolTip = monitoring.failureDescription
            menu.addItem(permissionItem)
        }
        let updateItem = NSMenuItem(title: NSLocalizedString("button.checkUpdates", comment: ""),
                                    action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

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

    private func setupEventMonitor() {
        guard eventMonitor == nil, localEventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeStatistics()
        }
        if let widgetsPanel {
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak widgetsPanel] event in
                if let self, let widgetsPanel, event.window !== widgetsPanel, event.window !== self.statusView?.window {
                    self.closeStatistics()
                }
                return event
            }
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        eventMonitor = nil
        localEventMonitor = nil
    }

    // MARK: - 操作

    private var isShowingStatistics: Bool {
        classicPopover?.isShown == true || widgetsPanel?.isDismissing == false
    }

    private func toggleStatistics() {
        if isShowingStatistics {
            closeStatistics()
        } else {
            showStatistics()
        }
    }

    private func showContextMenu() {
        closeStatistics()
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

    @objc private func requestMonitoring() {
        if MonitoringStatus.shared.failureDescription != nil {
            AppDelegate.shared?.retryMonitoring()
        } else {
            AppDelegate.shared?.requestAccessibilityPermission(analyticsSource: "context_menu")
        }
    }

    @objc private func checkForUpdates() { UpdateManager.shared.checkForUpdates() }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func armGeminiPreview() { pendingGeminiPreview = UUID() }

    func showStatistics() {
        guard !isShowingStatistics else { return }
        if let classicPopover { releaseClassicPopover(classicPopover) }
        widgetsPanel?.dismiss(animated: false)
        let popoverStyle = MenuPresentation.load().popoverStyle
        let shown = popoverStyle.map(showClassicPopover(style:)) ?? showWidgetsPanel()
        guard shown else { return }
        setupEventMonitor()
        AppDelegate.trackClick("tray_icon")
        AppDelegate.trackPageView("stats_popup")
    }

    private func showWidgetsPanel() -> Bool {
        guard let screen = statusView?.window?.screen ?? statusItem.button?.window?.screen ?? NSScreen.main else { return false }
        let panel = MenuWidgetsPanel(screen: screen, configuration: MenuWidgetPreferences.load(),
                                     constellationHistory: constellationHistory)
        if let request = pendingGeminiPreview {
            panel.claimGeminiPreview = { [weak self] in
                guard let self, self.pendingGeminiPreview == request else { return false }
                self.pendingGeminiPreview = nil
                return true
            }
        }
        panel.onRequestClose = { [weak self] in self?.closeStatistics() }
        panel.onOpenSettings = { [weak self] in
            self?.closeStatistics()
            SettingsWindowController.shared.show(page: .appearance)
        }
        panel.onDismiss = { [weak self] in self?.widgetsPanel = nil }
        widgetsPanel = panel
        panel.present()
        return panel.isVisible
    }

    private func showClassicPopover(style: MenuUIStyle) -> Bool {
        let anchor: NSView? = statusView?.window == nil ? statusItem.button : statusView
        guard let anchor, anchor.window != nil else { return false }

        let popover = NSPopover()
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = false
        classicPopover = popover
        classicStyle = style

        let controller: NSViewController & MenuStatsPresenting
        if classicStyle == .geek { controller = GeekStatsPopoverViewController() }
        else { controller = StatsPopoverViewController() }
        controller.historySelection = classicHistorySelections[classicStyle] ?? MenuHistorySelection()
        controller.preferredSizeDidChange = { [weak popover] size in popover?.contentSize = size }
        popover.contentViewController = controller

        NSApp.activate(ignoringOtherApps: true)
        controller.prepareForPopoverPresentation()
        popover.contentSize = controller.preferredContentSize
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        controller.view.window?.makeKey()
        if !popover.isShown { releaseClassicPopover(popover) }
        return popover.isShown
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        releaseClassicPopover(popover)
    }

    private func releaseClassicPopover(_ popover: NSPopover) {
        guard classicPopover === popover else { return }
        removeEventMonitor()
        if let controller = popover.contentViewController as? MenuStatsPresenting {
            classicHistorySelections[classicStyle] = controller.historySelection
            controller.preferredSizeDidChange = nil
        }
        classicPopover = nil
        StatsManager.shared.discardPresentationHistory()
    }

    private func closeStatistics() {
        if let popover = classicPopover {
            popover.performClose(nil)
            if !popover.isShown { releaseClassicPopover(popover) }
            return
        }
        guard let widgetsPanel, !widgetsPanel.isDismissing else { return }
        constellationHistory = widgetsPanel.constellationHistory
        removeEventMonitor()
        widgetsPanel.dismiss()
        StatsManager.shared.discardPresentationHistory()
    }

    #if DEBUG
    func presentForGUIAcceptance() {
        guard AppLaunchMode.current == .guiAcceptance else { return }
        // The status item's window is attached after applicationDidFinishLaunching.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.showStatistics()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if let panel = self?.widgetsPanel {
                    NSLog("[GUI Acceptance] Menu widgets panel shown=\(panel.isVisible) size=\(panel.frame.size)")
                } else if let popover = self?.classicPopover {
                    NSLog("[GUI Acceptance] Statistics popover shown=\(popover.isShown) size=\(popover.contentSize)")
                }
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

private protocol MenuStatsPresenting: AnyObject {
    var preferredSizeDidChange: ((NSSize) -> Void)? { get set }
    var preferredContentSize: NSSize { get }
    var historySelection: MenuHistorySelection { get set }
    func prepareForPopoverPresentation()
}

extension StatsPopoverViewController: MenuStatsPresenting {}
extension GeekStatsPopoverViewController: MenuStatsPresenting {}

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
