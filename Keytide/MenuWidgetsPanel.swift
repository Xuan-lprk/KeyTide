import Cocoa
import QuartzCore

final class MenuWidgetsPanel: NSPanel {
    typealias ConstellationHistory = [UUID: Set<KeyboardHeatmapWidget.Pattern>]

    private static var pendingMemoryRelief: DispatchWorkItem?
    private let card: NSView
    private let scrollView = NSScrollView()
    private let travel: CGFloat
    private var placements: [(configuration: MenuWidget, frame: NSRect)] = []
    private var visibleWidgets: [UUID: MenuWidgetContent] = [:]
    private var selectedDays: [UUID: Date] = [:]
    private(set) var constellationHistory: ConstellationHistory
    private var entranceFinished = false
    private var statsToken: UUID?
    private var scrollObserver: NSObjectProtocol?
    private var historyRefreshTimer: Timer?
    private var isPresentingWidgets = false
    private var needsMemoryRelief = false
    private(set) var isDismissing = false
    var onRequestClose: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onDismiss: (() -> Void)?
    var claimGeminiPreview: (() -> Bool)?

    convenience init(screen: NSScreen, configuration: [MenuWidget], constellationHistory: ConstellationHistory) {
        self.init(available: screen.visibleFrame, configuration: configuration, constellationHistory: constellationHistory)
    }

    init(available: NSRect, configuration: [MenuWidget], constellationHistory: ConstellationHistory = [:]) {
        let width = min(540, available.width)
        let allowsHalfWidth = width >= 500
        let rows = MenuWidget.rows(for: configuration, allowsHalfWidth: allowsHalfWidth)
        let rowHeights = rows.map { $0.map(Self.height).max() ?? 0 }
        let modulesHeight = rowHeights.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * 10
        let height = min(available.height, 84 + max(122, modulesHeight + 16))
        let frame = NSRect(x: available.maxX - width, y: available.maxY - height, width: width, height: height)
        card = NSView(frame: NSRect(x: 20, y: 20, width: width - 32, height: height - 28))
        let heatmapIDs = Set(configuration.filter { $0.kind == .heatmap }.map(\.id))
        self.constellationHistory = constellationHistory.filter { heatmapIDs.contains($0.key) }
        travel = width
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        title = NSLocalizedString("menu.widgets.panelTitle", comment: "Menu bar panel title")
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        level = .popUpMenu
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        animationBehavior = .none
        setFrame(frame, display: false)
        configureContent(size: frame.size, rows: rows, rowHeights: rowHeights,
                         modulesHeight: modulesHeight, allowsHalfWidth: allowsHalfWidth)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(updateWidgetVisibility),
                           name: NSWindow.didChangeOcclusionStateNotification, object: self)
        for name in [NSApplication.didHideNotification, NSApplication.didChangeScreenParametersNotification] {
            center.addObserver(self, selector: #selector(requestClose), name: name, object: NSApp)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(requestClose),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    deinit {
        stopWidgets()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { requestClose() }
    override func performClose(_ sender: Any?) { requestClose() }

    @objc private func requestClose() { onRequestClose?() }
    @objc private func openSettings() { onOpenSettings?() }

    @objc private func openActivity() {
        requestClose()
        AllTimeStatsWindowController.shared.show()
    }

    @objc private func openAppStats() {
        requestClose()
        AppStatsWindowController.shared.show()
    }

    func present() {
        if let pending = Self.pendingMemoryRelief {
            pending.cancel()
            Self.pendingMemoryRelief = nil
            needsMemoryRelief = true
        }
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        revealHeatmapForGeminiPreview()
        if animate { card.layer?.transform = CATransform3DMakeTranslation(travel, 0, 0) }
        makeKeyAndOrderFront(nil)
        entranceFinished = !animate
        guard animate else { beginPresentingWidgets(); return }

        slide(from: travel, to: 0, duration: 0.34) { [weak self] in
            guard let self, !self.isDismissing else { return }
            self.entranceFinished = true
            // Claim a requested preview in layout order when two heatmaps are visible.
            for placement in self.placements {
                self.visibleWidgets[placement.configuration.id]?.start(claimGeminiPreview: self.claimGeminiPreview)
            }
        }
        // Give the shell a head start before the first visible charts read history.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { [weak self] in self?.beginPresentingWidgets() }
    }

    private func beginPresentingWidgets() {
        guard !isDismissing, !isPresentingWidgets, !placements.isEmpty else { return }
        isPresentingWidgets = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main) { [weak self] _ in self?.updateWidgetVisibility() }
        updateWidgetVisibility()
    }

    private func revealHeatmapForGeminiPreview() {
        guard claimGeminiPreview != nil, let heatmap = placements.first(where: { $0.configuration.kind == .heatmap }),
              !scrollView.documentVisibleRect.contains(heatmap.frame) else { return }
        let clip = scrollView.contentView
        var target = clip.bounds
        target.origin.y = max(0, heatmap.frame.minY - 4)
        clip.scroll(to: clip.constrainBoundsRect(target).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    func dismiss(animated: Bool = true) {
        stopWidgets()
        guard animated, isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finishDismissal()
            return
        }
        guard !isDismissing else { return }
        isDismissing = true
        ignoresMouseEvents = true
        slide(from: card.layer?.presentation()?.transform.m41 ?? 0, to: travel, duration: 0.20) { [weak self] in
            self?.finishDismissal()
        }
    }

    private func finishDismissal() {
        isDismissing = true
        let completion = onDismiss
        onDismiss = nil
        onRequestClose = nil
        onOpenSettings = nil
        orderOut(nil)
        card.layer?.removeAllAnimations()
        for id in visibleWidgets.keys { releaseWidget(id) }
        if needsMemoryRelief {
            needsMemoryRelief = false
            // Let AppKit finish teardown and coalesce rapid close/reopen cycles.
            let relief = DispatchWorkItem {
                Self.pendingMemoryRelief = nil
                DispatchQueue.global(qos: .utility).async {
                    _ = malloc_zone_pressure_relief(nil, 8 * 1024 * 1024)
                }
            }
            Self.pendingMemoryRelief = relief
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: relief)
        }
        completion?()
    }

    private func slide(from start: CGFloat, to end: CGFloat, duration: CFTimeInterval, completion: @escaping () -> Void) {
        guard let layer = card.layer else { completion(); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        layer.transform = CATransform3DMakeTranslation(end, 0, 0)
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = start
        animation.toValue = end
        animation.duration = duration
        animation.timingFunction = end == 0
            ? CAMediaTimingFunction(controlPoints: 0.2, 0.78, 0.24, 1)
            : CAMediaTimingFunction(name: .easeIn)
        layer.add(animation, forKey: "slide")
        CATransaction.commit()
    }

    private func refreshVisibleWidgets() {
        guard isPresentingWidgets, !visibleWidgets.isEmpty else { return }
        let stats = StatsManager.shared.displayCurrentStats()
        visibleWidgets.values.forEach { $0.refresh(stats) }
        guard historyRefreshTimer == nil, visibleWidgets.values.contains(where: \.hasDeferredHistoryUpdate) else { return }
        // Calendar and cumulative queries should not run at the live capture rate.
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.historyRefreshTimer = nil
            guard self.isPresentingWidgets else { return }
            let data = MenuWidgetHistoryData()
            self.visibleWidgets.values.forEach { $0.refreshHistory(data) }
        }
        historyRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func updateWidgetVisibility() {
        guard isPresentingWidgets, let document = scrollView.documentView else { return }
        let viewport = isVisible && occlusionState.contains(.visible) ? scrollView.documentVisibleRect : .zero
        let visible = placements.filter { viewport.intersects($0.frame) }
        let ids = Set(visible.map { $0.configuration.id })
        guard ids != Set(visibleWidgets.keys) else { return }

        let wasShowingHistory = visibleWidgets.values.contains(where: \.readsHistory)
        let isFirstScreen = visibleWidgets.isEmpty && !entranceFinished
        for id in visibleWidgets.keys where !ids.contains(id) { releaseWidget(id) }
        if !visible.isEmpty {
            needsMemoryRelief = true
            let stats = StatsManager.shared.displayCurrentStats()
            let history = MenuWidgetHistoryData()
            let entering = visible.filter { visibleWidgets[$0.configuration.id] == nil }
            for (configuration, frame) in entering {
                let id = configuration.id
                let widget = MenuWidgetContent(configuration: configuration, previousPatterns: constellationHistory[id] ?? [],
                                               selectedDay: selectedDays[id]) { [weak self] date in
                    self?.requestClose()
                    KeyboardHeatmapWindowController.shared.show(day: date)
                }
                visibleWidgets[id] = widget
                widget.view.frame = frame
                document.addSubview(widget.view)
                widget.refresh(stats)
                widget.refreshHistory(history)
                if entranceFinished { widget.start(claimGeminiPreview: claimGeminiPreview) }
            }
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                var row = 0
                var lastY = entering.first?.frame.minY
                for (configuration, frame) in entering {
                    if lastY != frame.minY { row += 1 }
                    lastY = frame.minY
                    visibleWidgets[configuration.id]?.view.reveal(openingRow: isFirstScreen ? row : nil)
                }
            }
            if statsToken == nil {
                statsToken = StatsManager.shared.addStatsUpdateHandler { [weak self] in self?.refreshVisibleWidgets() }
            }
        } else if let statsToken {
            StatsManager.shared.removeStatsUpdateHandler(statsToken)
            self.statsToken = nil
        }
        if !visibleWidgets.values.contains(where: \.hasDeferredHistoryUpdate) {
            historyRefreshTimer?.invalidate()
            historyRefreshTimer = nil
        }
        if wasShowingHistory && !visibleWidgets.values.contains(where: \.readsHistory) {
            StatsManager.shared.discardPresentationHistory()
        }
    }

    private func releaseWidget(_ id: UUID) {
        guard let widget = visibleWidgets.removeValue(forKey: id) else { return }
        constellationHistory[id] = widget.lastConstellationPatterns
        selectedDays[id] = widget.selectedDay
        if isPresentingWidgets { widget.stop() }
        widget.view.layer?.removeAnimation(forKey: "widgetReveal")
        widget.view.removeFromSuperview()
    }

    private func stopWidgets() {
        isPresentingWidgets = false
        historyRefreshTimer?.invalidate()
        historyRefreshTimer = nil
        visibleWidgets.values.forEach { $0.stop() }
        if let statsToken { StatsManager.shared.removeStatsUpdateHandler(statsToken) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        statsToken = nil
        scrollObserver = nil
    }

    private func configureContent(size: NSSize, rows: [[MenuWidget]], rowHeights: [CGFloat],
                                  modulesHeight: CGFloat, allowsHalfWidth: Bool) {
        let clip = NSView(frame: NSRect(origin: .zero, size: size))
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        contentView = clip
        let radius: CGFloat = 18
        card.wantsLayer = true
        card.layer?.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.24
        card.layer?.shadowRadius = 9
        card.layer?.shadowOffset = NSSize(width: 0, height: -3)
        clip.addSubview(card)

        let surface = MenuWidgetSurface(frame: card.bounds, radius: radius, panel: true)
        card.addSubview(surface)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        let actions = NSStackView(views: [
            iconButton("chart.bar.xaxis", key: "allTimeStats.button", action: #selector(openActivity)),
            iconButton("square.grid.2x2", key: "appStats.button", action: #selector(openAppStats)),
            iconButton("gearshape", key: "settings.title", action: #selector(openSettings)),
            iconButton("xmark", key: "menu.widgets.close", action: #selector(requestClose))
        ])
        actions.spacing = 5

        for child in [heading, actions, scrollView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(child)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            heading.centerYAnchor.constraint(equalTo: actions.centerYAnchor),
            actions.topAnchor.constraint(equalTo: surface.topAnchor, constant: 10),
            actions.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: card.bounds.width, height: max(122, modulesHeight + 16)))
        document.autoresizingMask = [.width]
        scrollView.documentView = document

        if rows.isEmpty {
            let button = NSButton(title: NSLocalizedString("menu.widgets.configure", comment: ""), target: self, action: #selector(openSettings))
            let message = NSTextField(wrappingLabelWithString: NSLocalizedString("menu.widgets.empty", comment: ""))
            message.alignment = .center
            message.textColor = .secondaryLabelColor
            let empty = NSStackView(views: [message, button])
            empty.orientation = .vertical
            empty.alignment = .centerX
            empty.spacing = 10
            empty.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.centerXAnchor.constraint(equalTo: document.centerXAnchor),
                empty.centerYAnchor.constraint(equalTo: document.centerYAnchor),
                empty.widthAnchor.constraint(lessThanOrEqualTo: document.widthAnchor, constant: -32)
            ])
        }
        let contentWidth = card.bounds.width - 24
        let halfWidth = (contentWidth - 10) / 2
        var y: CGFloat = 4
        for (row, height) in zip(rows, rowHeights) {
            var x: CGFloat = 12
            for item in row {
                let width = allowsHalfWidth && item.usesHalfWidth ? halfWidth : contentWidth
                placements.append((item, NSRect(x: x, y: y, width: width, height: height)))
                x += width + 10
            }
            y += height + 10
        }
        surface.layoutSubtreeIfNeeded()
    }

    private func iconButton(_ symbol: String, key: String, action: Selector) -> NSButton {
        let name = NSLocalizedString(key, comment: "")
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: name) ?? NSImage(),
                              target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = name
        button.setAccessibilityLabel(name)
        button.contentTintColor = .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 26)
        ])
        return button
    }

    private static func height(for widget: MenuWidget) -> CGFloat {
        switch widget.kind {
        case .pulse: return 148
        case .today: return 107
        case .keys: return MenuTopKeysView.cardHeight
        case .history: return 174
        case .mouse: return 111
        case .heatmap: return KeyboardHeatmapWidget.contentHeight + 16
        case .activity: return 164
        case .calendar: return 139
        case .apps: return 198
        case .totals: return 151
        case .peaks: return 107
        }
    }
}

/// Shares the expensive projections across all widgets in a single refresh.
private final class MenuWidgetHistoryData {
    lazy var days = StatsManager.shared.heatmapActivityData().map {
        ActivityHeatmapView.DayActivity(date: $0.date, keyPresses: $0.keyPresses, clicks: $0.clicks)
    }
    lazy var totals = StatsManager.shared.getAllTimeStats()
    private var apps: [Bool: [AppStats]] = [:]

    func appSummary(monthly: Bool) -> [AppStats] {
        if let cached = apps[monthly] { return cached }
        let summary = StatsManager.shared.appStatsSummary(range: monthly ? .month : .week)
        apps[monthly] = summary
        return summary
    }
}

private final class MenuWidgetSurface: NSView {
    private let panel: Bool
    private let fill: NSColor?

    init(frame: NSRect = .zero, radius: CGFloat, panel: Bool = false, fill: NSColor? = nil) {
        self.panel = panel
        self.fill = fill
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        updateColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reveal(openingRow: Int?) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak layer] in layer?.removeAnimation(forKey: "widgetReveal") }
        defer { CATransaction.commit() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = openingRow == nil ? 0.12 : 0.17
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        guard let openingRow else {
            layer.add(fade, forKey: "widgetReveal")
            return
        }

        let settle = CAKeyframeAnimation(keyPath: "transform.translation.x")
        settle.values = [16, -2, 0]
        settle.keyTimes = [0, 0.70, 1]
        settle.duration = 0.26
        settle.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]

        // Relative to the first committed frame, including on a cold layout.
        let delay = Double(min(openingRow, 4)) * 0.028
        for animation in [fade as CAAnimation, settle] {
            animation.beginTime = delay
            animation.fillMode = .backwards
        }
        let reveal = CAAnimationGroup()
        reveal.animations = [fade, settle]
        reveal.duration = delay + settle.duration
        layer.add(reveal, forKey: "widgetReveal")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = fill ?? (panel
            ? (dark ? NSColor(srgbRed: 0.078, green: 0.102, blue: 0.129, alpha: 1) : .white)
            : NSColor.labelColor.withAlphaComponent(dark ? 0.065 : 0.045))
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.cgColor }
    }
}

private protocol MenuPulseRendering: AnyObject {
    func start()
    func stop()
    func append(currentKPS: Int, currentCPS: Int)
    func emitImpulse()
}
extension TypingPulseView: MenuPulseRendering {}
extension GeekTypingPulseView: MenuPulseRendering {}

private final class MenuWidgetContent {
    private let kind: MenuWidgetKind
    private(set) var selectedDay: Date?
    let view: MenuWidgetSurface
    private var refreshStats: (DailyStats) -> Void = { _ in }
    private var updateHistory: ((MenuWidgetHistoryData) -> Void)?
    private var heatmap: KeyboardHeatmapWidget?
    private var pulse: (NSView & MenuPulseRendering)?
    private var rateTimer: Timer?

    var hasDeferredHistoryUpdate: Bool { updateHistory != nil }
    var readsHistory: Bool { kind == .history || hasDeferredHistoryUpdate }
    var lastConstellationPatterns: Set<KeyboardHeatmapWidget.Pattern>? { heatmap?.lastConstellationPatterns }

    init(configuration: MenuWidget, previousPatterns: Set<KeyboardHeatmapWidget.Pattern>, selectedDay: Date?,
         openDay: @escaping (Date) -> Void) {
        self.selectedDay = selectedDay
        kind = configuration.kind
        let geek = configuration.style == .geek && kind != .heatmap
        view = MenuWidgetSurface(radius: 12, fill: geek ? GeekPalette.panel : nil)
        if geek { view.appearance = NSAppearance(named: .darkAqua) }
        let body: NSView
        switch kind {
        case .pulse:
            let renderer: NSView & MenuPulseRendering = geek ? GeekTypingPulseView() : TypingPulseView()
            pulse = renderer
            refreshStats = { [weak renderer] _ in renderer?.emitImpulse() }
            body = renderer
        case .today:
            body = today(geek: geek)
        case .keys:
            let keys = MenuTopKeysView(style: configuration.style)
            refreshStats = { [weak keys] stats in keys?.update(counts: stats.keyPressCounts) }
            body = keys
        case .history:
            body = history(configuration: configuration, geek: geek, openDay: openDay)
        case .mouse:
            body = mouse(geek: geek)
        case .heatmap:
            let widget = KeyboardHeatmapWidget(theme: configuration.heatmapTheme, effect: configuration.heatmapEffect,
                                               previousPatterns: previousPatterns)
            heatmap = widget
            refreshStats = { [weak widget] stats in widget?.refresh(stats) }
            body = widget
        case .activity:
            body = activity(monthly: configuration.monthly, openDay: openDay)
        case .calendar:
            body = calendar(metric: configuration.displayMetric, openDay: openDay)
        case .apps:
            body = appRanking(configuration: configuration, geek: geek)
        case .totals:
            body = totals(geek: geek)
        case .peaks:
            body = peaks(geek: geek)
        }

        let content: NSView
        if kind == .heatmap || kind == .pulse { content = body }
        else {
            let title = NSTextField(labelWithString: kind.title)
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            let stack = Self.stack([title, body], orientation: .vertical, spacing: 6)
            stack.alignment = .leading
            body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            body.setContentHuggingPriority(.defaultLow, for: .vertical)
            content = stack
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
    }

    deinit { rateTimer?.invalidate() }

    func refresh(_ stats: DailyStats) { refreshStats(stats) }

    func refreshHistory(_ data: MenuWidgetHistoryData) { updateHistory?(data) }

    func start(claimGeminiPreview: (() -> Bool)?) {
        if let heatmap { heatmap.start(previewGemini: claimGeminiPreview?() ?? false) }
        guard let pulse, rateTimer == nil else { return }
        pulse.start()
        sampleRates()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.sampleRates()
        }
        rateTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        heatmap?.stop()
        rateTimer?.invalidate()
        rateTimer = nil
        pulse?.stop()
    }

    private func sampleRates() {
        let snapshot = StatsManager.shared.currentRatesSnapshot()
        pulse?.append(currentKPS: snapshot.currentKPS, currentCPS: snapshot.currentCPS)
    }

    private func today(geek: Bool) -> NSView {
        let keys = Self.metric("stats.keyPresses", icon: "keyboard", geek: geek, prominent: true)
        let clicks = Self.metric("stats.totalClicks", icon: "computermouse", geek: geek, prominent: true)
        refreshStats = { stats in
            keys.update(stats.keyPresses.formatted())
            clicks.update(stats.totalClicks.formatted())
        }
        return Self.stack([keys.view, clicks.view], orientation: .horizontal, spacing: 14, equal: true)
    }

    private func history(configuration: MenuWidget, geek: Bool, openDay: @escaping (Date) -> Void) -> NSView {
        let range: StatsManager.HistoryRange = configuration.monthly ? .month : .week
        let metric: StatsManager.HistoryMetric
        switch configuration.displayMetric {
        case .keys, .combined: metric = .keyPresses
        case .clicks: metric = .clicks
        case .movement: metric = .mouseDistance
        case .scroll: metric = .scrollDistance
        }
        let summary = NSTextField(labelWithString: "")
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        let refreshChart: ([(date: Date, value: Double)]) -> Void
        let chart: NSView
        if geek {
            let renderer = GeekStatsChartView()
            renderer.onOpenDay = openDay
            refreshChart = { renderer.apply(series: $0, metric: metric, range: range, style: configuration.bars ? .bar : .line, animated: false) }
            chart = renderer
        } else {
            let renderer = StatsChartView()
            renderer.onOpenDay = openDay
            refreshChart = { renderer.apply(series: $0, metric: metric, range: range, style: configuration.bars ? .bar : .line, animated: false) }
            chart = renderer
        }
        let stack = Self.stack([chart, summary], orientation: .vertical, spacing: 4)
        stack.alignment = .leading
        chart.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        chart.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        let rangeName = NSLocalizedString(configuration.monthly ? "history.range.month" : "history.range.week", comment: "")
        refreshStats = { _ in
            let manager = StatsManager.shared
            let points = manager.historyTrendSeries(range: range, metric: metric).display
            refreshChart(points)
            let total = manager.formatHistoryValue(metric: metric, value: points.reduce(0) { $0 + $1.value })
            summary.stringValue = "\(configuration.displayMetric.title) · \(rangeName) · " +
                String(format: NSLocalizedString("history.total", comment: ""), total)
        }
        return stack
    }

    private func activity(monthly: Bool, openDay: @escaping (Date) -> Void) -> NSView {
        let chart = ActivityOverviewView()
        let keys = Self.chartLegend("history.metric.keys", color: ActivityOverviewView.keysColor)
        let clicks = Self.chartLegend("history.metric.clicks", color: ActivityOverviewView.clicksColor)
        let period = Self.caption(NSLocalizedString(monthly ? "history.range.month" : "history.range.week", comment: ""))
        period.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let legend = Self.stack([keys, clicks, period], orientation: .horizontal, spacing: 10)
        legend.alignment = .centerY
        let content = Self.stack([chart, legend], orientation: .vertical, spacing: 4)
        content.alignment = .leading
        chart.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        chart.heightAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true
        legend.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor).isActive = true

        var days: [ActivityHeatmapView.DayActivity] = []
        chart.onSelectionChanged = { [weak self] index in self?.selectedDay = days[index].date }
        chart.onSelectionCleared = { [weak self] in self?.selectedDay = nil }
        chart.onOpenDay = { index in
            guard days.indices.contains(index) else { return }
            openDay(days[index].date)
        }
        updateHistory = { [weak self] data in
            let next = Array(data.days.suffix(monthly ? 30 : 7))
            guard next != days else { return }
            days = next
            chart.update(days: next, selectedDate: self?.selectedDay)
            self?.selectedDay = chart.selectedIndex.map { days[$0].date }
        }
        return content
    }

    private func calendar(metric: MenuWidget.Metric, openDay: @escaping (Date) -> Void) -> NSView {
        let chart = ActivityHeatmapView()
        switch metric {
        case .keys: chart.metric = .keys
        case .clicks: chart.metric = .clicks
        default: chart.metric = .combined
        }
        chart.onOpenDay = openDay
        chart.onSelectionChanged = { [weak self] day in self?.selectedDay = day?.date }
        updateHistory = { [weak self] data in
            guard chart.activityData != data.days else { return }
            let restore = chart.activityData.isEmpty ? self?.selectedDay : nil
            chart.activityData = data.days
            if let restore, let index = data.days.firstIndex(where: { $0.date == restore }) {
                chart.selectDay(at: index)
            }
        }
        return chart
    }

    private func appRanking(configuration: MenuWidget, geek: Bool) -> NSView {
        let metric = configuration.displayMetric
        let sort: AppStatsSortMetric
        let value: (AppStats) -> Double
        let format: (AppStats) -> String
        switch metric {
        case .clicks:
            sort = .clicks
            value = { Double($0.totalClicks) }
            format = { $0.totalClicks.formatted() }
        case .scroll:
            sort = .scroll
            value = { $0.scrollDistance }
            format = { StatsManager.shared.formatHistoryValue(metric: .scrollDistance, value: $0.scrollDistance) }
        default:
            sort = .keys
            value = { Double($0.keyPresses) }
            format = { $0.keyPresses.formatted() }
        }
        let tint: NSColor = metric == .clicks ? (geek ? GeekPalette.amber : .systemOrange) : (geek ? GeekPalette.cyan : .systemBlue)
        let ranking = MenuAppRankingView(tint: tint)
        let period = NSLocalizedString(configuration.monthly ? "history.range.month" : "history.range.week", comment: "")
        let footer = Self.caption("\(metric.title) · \(period)")
        let content = Self.stack([ranking, footer], orientation: .vertical, spacing: 4)
        content.alignment = .leading
        ranking.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        footer.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor).isActive = true
        let displayName: (AppStats) -> String = { app in
            app.displayName.isEmpty ? NSLocalizedString("appStats.unknownApp", comment: "") : app.displayName
        }
        updateHistory = { data in
            let enabled = StatsManager.shared.appStatsEnabled
            guard enabled else {
                ranking.update([], emptyMessage: NSLocalizedString("appStats.disabled", comment: ""))
                return
            }
            let items = data.appSummary(monthly: configuration.monthly).filter {
                let amount = value($0)
                return amount.isFinite && amount > 0
            }
            let sorted = AppStatsListFilter.apply(items: items, query: "", displayName: displayName, sortMetric: sort, ascending: false)
            let maximum = sorted.first.map(value) ?? 1
            let rows = sorted.prefix(5).map {
                MenuAppRankingView.Entry(name: displayName($0), value: format($0), fraction: CGFloat(value($0) / maximum))
            }
            ranking.update(rows, emptyMessage: NSLocalizedString("appStats.empty", comment: ""))
        }
        return content
    }

    private func totals(geek: Bool) -> NSView {
        let keys = Self.metric("stats.keyPresses", icon: "keyboard", geek: geek, prominent: true)
        let clicks = Self.metric("stats.totalClicks", icon: "computermouse", geek: geek, prominent: true)
        let distance = Self.metric("stats.mouseDistance", icon: "cursorarrow.motionlines", geek: geek, prominent: true)
        let scroll = Self.metric("stats.scrollDistance", icon: "scroll", geek: geek, prominent: true)
        let countRow = Self.stack([keys.view, clicks.view], orientation: .horizontal, spacing: 14, equal: true)
        let distanceRow = Self.stack([distance.view, scroll.view], orientation: .horizontal, spacing: 14, equal: true)
        let content = Self.stack([countRow, distanceRow], orientation: .vertical, spacing: 5)
        content.alignment = .leading
        for row in [countRow, distanceRow] { row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        updateHistory = { data in
            let stats = data.totals
            keys.update(stats.totalKeyPresses.formatted())
            clicks.update(stats.totalClicks.formatted())
            distance.update(stats.formattedMouseDistance)
            scroll.update(stats.formattedScrollDistance)
        }
        return content
    }

    private func peaks(geek: Bool) -> NSView {
        let keys = Self.metric("kpsDetail.kps", icon: "keyboard", geek: geek, prominent: true)
        let clicks = Self.metric("kpsDetail.cps", icon: "computermouse", geek: geek, prominent: true)
        refreshStats = { stats in
            keys.update(stats.peakKPS.formatted())
            clicks.update(stats.peakCPS.formatted())
        }
        return Self.stack([keys.view, clicks.view], orientation: .horizontal, spacing: 14, equal: true)
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private static func chartLegend(_ key: String, color: NSColor) -> NSView {
        let dot = NSTextField(labelWithString: "●")
        dot.font = .systemFont(ofSize: 8)
        dot.textColor = color
        dot.setAccessibilityElement(false)
        let marker = stack([dot, caption(NSLocalizedString(key, comment: ""))], orientation: .horizontal, spacing: 4)
        marker.alignment = .centerY
        return marker
    }

    private func mouse(geek: Bool) -> NSView {
        let labels = ["popover.mouse.left", "popover.mouse.middle", "popover.mouse.right", "popover.mouse.back",
                      "popover.mouse.forward", "popover.mouse.movement", "popover.mouse.scroll"]
        let metrics = labels.map { Self.metric($0, icon: "", geek: geek, prominent: false) }
        let rows = [metrics[0..<3], metrics[3..<5], metrics[5..<7]].map {
            Self.stack($0.map(\.view), orientation: .horizontal, spacing: 10, equal: true)
        }
        let stack = Self.stack(rows, orientation: .vertical, spacing: 2, equal: true)
        stack.alignment = .leading
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        refreshStats = { stats in
            let values = [stats.leftClicks.formatted(), stats.middleClicks.formatted(), stats.rightClicks.formatted(),
                          stats.sideBackClicks.formatted(), stats.sideForwardClicks.formatted(),
                          stats.formattedMouseDistance, stats.formattedScrollDistance]
            for (metric, value) in zip(metrics, values) { metric.update(value) }
        }
        return stack
    }

    private static func metric(_ key: String, icon: String, geek: Bool, prominent: Bool) -> (view: NSView, update: (String) -> Void) {
        let title = NSLocalizedString(key, comment: "")
        if geek {
            let item = GeekStatItemView(icon: icon, title: title, value: "0", prominent: prominent, compact: !prominent)
            return (item, item.updateValue)
        }
        let item = StatItemView(icon: icon, title: title, value: "0", prominent: prominent, compact: !prominent)
        return (item, item.updateValue)
    }

    private static func stack(_ views: [NSView], orientation: NSUserInterfaceLayoutOrientation, spacing: CGFloat,
                              equal: Bool = false) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.spacing = spacing
        stack.distribution = equal ? .fillEqually : .fill
        return stack
    }
}

private final class MenuAppRankingView: NSView {
    struct Entry: Equatable {
        let name: String
        let value: String
        let fraction: CGFloat
    }

    private let rows: [Row]
    private let empty = NSTextField(wrappingLabelWithString: "")

    init(tint: NSColor) {
        rows = (0..<5).map { _ in Row(tint: tint) }
        super.init(frame: .zero)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.detachesHiddenViews = false
        stack.spacing = 3
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 11)
        empty.alignment = .center
        for view in [stack, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor)
        ])
        update([], emptyMessage: "")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ entries: [Entry], emptyMessage: String) {
        empty.isHidden = !entries.isEmpty
        if empty.stringValue != emptyMessage { empty.stringValue = emptyMessage }
        for (index, row) in rows.enumerated() {
            row.isHidden = !entries.indices.contains(index)
            if entries.indices.contains(index) { row.update(entries[index]) }
        }
    }

    private final class Row: NSView {
        private let name = NSTextField(labelWithString: "")
        private let value = NSTextField(labelWithString: "")
        private let tint: NSColor
        private var entry: Entry?

        init(tint: NSColor) {
            self.tint = tint
            super.init(frame: .zero)
            name.font = .systemFont(ofSize: 11, weight: .medium)
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            value.setContentCompressionResistancePriority(.required, for: .horizontal)
            for label in [name, value] {
                label.translatesAutoresizingMaskIntoConstraints = false
                label.setAccessibilityElement(false)
                addSubview(label)
            }
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 24),
                name.topAnchor.constraint(equalTo: topAnchor),
                name.leadingAnchor.constraint(equalTo: leadingAnchor),
                name.trailingAnchor.constraint(lessThanOrEqualTo: value.leadingAnchor, constant: -8),
                value.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
                value.trailingAnchor.constraint(equalTo: trailingAnchor)
            ])
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(_ item: Entry) {
            guard item != entry else { return }
            entry = item
            name.stringValue = item.name
            value.stringValue = item.value
            toolTip = "\(item.name) · \(item.value)"
            setAccessibilityLabel(toolTip)
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let entry else { return }
            let track = NSRect(x: 0, y: 3, width: bounds.width, height: 3)
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
            let fill = NSRect(x: track.minX, y: track.minY, width: track.width * entry.fraction, height: track.height)
            tint.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
