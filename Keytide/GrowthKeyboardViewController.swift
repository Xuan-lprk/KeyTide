import Cocoa

/// Production page: formal StatsManager data, cached renderer and bounded playback.
/// Today refreshes on presentation/activation, Today and explicit Refresh; no event subscription.
final class GrowthKeyboardViewController: NSViewController {
    private let loadPresentation: () -> GrowthKeyboardPresentation?
    private let startsIn3D: Bool
    private let loadReplay: ((String, @escaping (Result<GrowthReplayPressPlan, Error>) -> Void) -> (() -> Void))?
    private var cancelReplayLoad: (() -> Void)?
    private let playback = GrowthPlaybackDriver()
    private var presentation: GrowthKeyboardPresentation?
    private var displayedKeyUsages: [GrowthKeyboardKeyUsage] = []
    private var displayedMediaCounts: [String: Int]? = [:]
    private struct Presented3DState {
        let frame: GrowthKeyboardFrame
        let date: String
        let total: String
        let coverage: String
        let metric: String
        let scope: String
    }
    private var presented3DState: Presented3DState?
    private var selectionGeneration = 0
    private let renderer = EditorialKeyboardRenderer(frame: .zero)
    private var spatialRenderer: GrowthKeyboard3DRenderer?
    private(set) var usesMechanical = false
    private let rendererHost = NSView()
    private let transport = NSView()
    private var transportContent: NSView?
    var transportView: NSView { transport }
    var onSelectionChanged: ((GrowthKeyboardSidebarSelection?) -> Void)?
    var onSummaryChanged: ((String, String, String) -> Void)?
    private let scopeSelector = NSPopUpButton()
    private let rangeStartPicker = NSDatePicker()
    private let rangeSeparator = NSTextField(labelWithString: "–")
    private var previousScope = 0
    private var example: KeyReplayExample?
    private var realDateBeforeExample: Date?
    private var realScopeBeforeExample = 0
    private var isExample: Bool { scope == 3 }
    private var usesTimeline: Bool { scope == 0 || isExample }
    private var inspectionDate: Date?
    private var rangeStart: Date?
    private var displayedMetricTitle: String?
    private(set) var displayedScopeTitle: String = NSLocalizedString("keyboard.mode.growth", comment: "")
    var metricTitle: String { displayedMetricTitle ?? text("growth.metric.caption") }
    private var scope: Int { scopeSelector.indexOfSelectedItem }

    private let modeSelector = NSSegmentedControl()
    private var shows3D: Bool { modeSelector.selectedSegment == 1 }
    private var isPlaybackRunning: Bool { playback.state.isPlaying || playback.isPresentingPlaybackFrame }
    private var observers: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?
    private var isPresented = false
    private let dateLabel = NSTextField(labelWithString: "")
    private let totalLabel = NSTextField(labelWithString: "")
    private let coverageLabel = NSTextField(wrappingLabelWithString: "")
    private let datePicker = NSDatePicker()
    private let slider = NSSlider()
    private let timelineStart = NSTextField(labelWithString: "")
    private let timelineEnd = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private let play = NSButton()
    private let today = NSButton()
    private let refresh = NSButton()
    private let numberFormatter: NumberFormatter = {
        let value = NumberFormatter(); value.numberStyle = .decimal; return value
    }()
    private let dateFormatter: DateFormatter = {
        let value = DateFormatter(); value.dateStyle = .medium; value.timeStyle = .none; return value
    }()

    init(manager: StatsManager, startsIn3D: Bool = false,
         loadReplay: ((String, @escaping (Result<GrowthReplayPressPlan, Error>) -> Void) -> (() -> Void))? = nil) {
        self.startsIn3D = startsIn3D
        self.loadReplay = loadReplay
        loadPresentation = { GrowthKeyboardPresentation.load(from: manager) }
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { pausePlayback(); observers.forEach { NotificationCenter.default.removeObserver($0) } }

    struct BrowsingState {
        let scope: Int
        let inspectionDate: Date?
        let rangeStart: Date?
        let realScopeBeforeExample: Int
        let realDateBeforeExample: Date?
    }

    var browsingState: BrowsingState {
        BrowsingState(scope: scope, inspectionDate: inspectionDate, rangeStart: rangeStart,
                      realScopeBeforeExample: realScopeBeforeExample, realDateBeforeExample: realDateBeforeExample)
    }

    func restoreBrowsing(_ state: BrowsingState) {
        _ = view
        scopeSelector.selectItem(at: state.scope)
        previousScope = state.scope
        inspectionDate = state.inspectionDate
        rangeStart = state.rangeStart
        realScopeBeforeExample = state.realScopeBeforeExample
        realDateBeforeExample = state.realDateBeforeExample
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 620))
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0)
        ])

        modeSelector.segmentCount = 2
        modeSelector.setLabel(text("growth.mode.editorial"), forSegment: 0)
        modeSelector.setLabel(text("growth.mode.3d"), forSegment: 1)
        modeSelector.selectedSegment = 0; modeSelector.isHidden = startsIn3D
        modeSelector.segmentStyle = .rounded
        modeSelector.target = self; modeSelector.action = #selector(changeDisplayMode)
        modeSelector.setAccessibilityLabel(text("growth.mode.choose"))
        let header = NSStackView(views: [modeSelector])
        header.spacing = 10; header.alignment = .firstBaseline
        header.isHidden = startsIn3D
        add(header, to: stack)

        rendererHost.setContentHuggingPriority(.defaultLow, for: .vertical)
        rendererHost.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        add(rendererHost, to: stack)
        rendererHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        installRenderer(renderer)

        func button(_ value: NSButton, _ title: String, _ action: Selector) -> NSButton {
            value.title = title; value.bezelStyle = .rounded; value.target = self; value.action = action
            value.font = .systemFont(ofSize: 12)
            return value
        }
        button(previous, "‹", #selector(previousDay)).setAccessibilityLabel(text("growth.previous"))
        button(next, "›", #selector(nextDay)).setAccessibilityLabel(text("growth.next"))
        for (control, symbol) in [(previous, "chevron.left"), (next, "chevron.right")] {
            control.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            control.imagePosition = .imageOnly
            control.widthAnchor.constraint(equalToConstant: 28).isActive = true
        }
        datePicker.datePickerStyle = .textField
        datePicker.datePickerElements = [.yearMonthDay]
        datePicker.isBordered = false; datePicker.drawsBackground = false
        datePicker.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        datePicker.target = self; datePicker.action = #selector(pickDate)
        datePicker.setAccessibilityLabel(text("growth.date"))
        datePicker.widthAnchor.constraint(equalToConstant: 130).isActive = true
        scopeSelector.addItems(withTitles: [text("keyboard.scope.cumulative"), text("keyboard.scope.day"), text("keyboard.scope.range"), text("replay.example.scope")])
        scopeSelector.target = self; scopeSelector.action = #selector(changeScope)
        scopeSelector.controlSize = .small
        scopeSelector.setAccessibilityLabel(text("keyboard.scope.choose"))
        scopeSelector.widthAnchor.constraint(equalToConstant: 120).isActive = true
        rangeStartPicker.datePickerStyle = .textField
        rangeStartPicker.datePickerElements = [.yearMonthDay]
        rangeStartPicker.isBordered = false; rangeStartPicker.drawsBackground = false
        rangeStartPicker.font = datePicker.font
        rangeStartPicker.widthAnchor.constraint(equalToConstant: 130).isActive = true
        rangeStartPicker.target = self; rangeStartPicker.action = #selector(pickRangeStart)
        rangeStartPicker.setAccessibilityLabel(text("keyboard.scope.start"))
        button(play, text("growth.play"), #selector(togglePlayback))
        play.font = .systemFont(ofSize: 12, weight: .semibold)
        play.imagePosition = .imageLeft
        play.widthAnchor.constraint(greaterThanOrEqualToConstant: 142).isActive = true
        button(today, text("growth.today"), #selector(showToday))
        button(refresh, text("growth.refresh"), #selector(refreshToday))
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refresh.imagePosition = .imageOnly; refresh.toolTip = text("growth.refresh")
        refresh.setAccessibilityLabel(text("growth.refresh"))
        refresh.widthAnchor.constraint(equalToConstant: 28).isActive = true
        slider.target = self; slider.action = #selector(scrub); slider.isContinuous = true
        slider.setAccessibilityLabel(text("growth.timeline"))
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for endpoint in [timelineStart, timelineEnd] {
            endpoint.font = .systemFont(ofSize: 10)
            endpoint.textColor = .secondaryLabelColor
            endpoint.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let timeline = NSStackView(views: [timelineStart, slider, timelineEnd])
        timeline.spacing = 12; timeline.alignment = .centerY
        if startsIn3D {
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
            timelineStart.stringValue = NSLocalizedString("growth.day.one.short", comment: "Growth Keyboard")
            timelineEnd.stringValue = NSLocalizedString("growth.today.short", comment: "Growth Keyboard")
            let replay = NSStackView(views: [scopeSelector, play, previous, rangeStartPicker, rangeSeparator, datePicker, next, refresh,
                slider, today])
            replay.spacing = 8; replay.alignment = .centerY
            replay.translatesAutoresizingMaskIntoConstraints = false
            transportContent = replay
            transport.addSubview(replay)
            NSLayoutConstraint.activate([
                replay.leadingAnchor.constraint(equalTo: transport.leadingAnchor),
                replay.trailingAnchor.constraint(equalTo: transport.trailingAnchor),
                replay.centerYAnchor.constraint(equalTo: transport.centerYAnchor)
            ])
        } else {
            let navigation = NSStackView(views: [previous, datePicker, next, flexibleSpace(), refresh])
            navigation.spacing = 8; navigation.alignment = .centerY
            let replayHeading = NSStackView(views: [caption("growth.replay.title"), flexibleSpace(), today])
            replayHeading.alignment = .centerY
            let replay = column([replayHeading, play, navigation, timeline], spacing: 9)
            for child in [replayHeading, play, navigation, timeline] {
                child.translatesAutoresizingMaskIntoConstraints = false
                child.widthAnchor.constraint(equalTo: replay.widthAnchor).isActive = true
            }
            transportContent = replay
            add(replay, to: stack)
        }
        renderer.onSelectionChanged = { [weak self] in self?.showKeyDetail($0) }
        playback.onChange = { [weak self] _ in self?.renderSelection() }
        updateControls(); showKeyDetail(nil)
        if startsIn3D { modeSelector.selectedSegment = 1; changeDisplayMode() }
    }

    func clearKeySelection() {
        if shows3D { spatialRenderer?.selectKey(nil) }
        else { renderer.selectKey(nil) }
    }

    func setTransportCollapsed(_ collapsed: Bool) {
        transportContent?.isHidden = collapsed
        if collapsed { pausePlayback(); renderSelection() }
        updateControls()
    }

    func refreshCanvas() {
        if shows3D {
            spatialRenderer?.refreshFrame()
        } else {
            view.needsDisplay = true
        }
    }

    func updateDisplayResolution() { spatialRenderer?.updateDisplayResolution() }

    /// Screen-space key bounds in this page's coordinates, used by the Studio
    /// to position detail without introducing another selection model.
    func selectedKeyFrame() -> CGRect? {
        if shows3D, let spatialRenderer, let frame = spatialRenderer.selectedKeyFrame() {
            return spatialRenderer.convert(frame, to: view)
        }
        return nil
    }

    private func caption(_ key: String) -> NSTextField {
        let label = NSTextField(labelWithString: text(key))
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }
    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        return stack
    }
    private func flexibleSpace() -> NSView {
        let space = NSView()
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return space
    }
    private func add(_ child: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(child)
        child.translatesAutoresizingMaskIntoConstraints = false
        child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func installRenderer(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        rendererHost.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: rendererHost.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: rendererHost.trailingAnchor),
            child.topAnchor.constraint(equalTo: rendererHost.topAnchor),
            child.bottomAnchor.constraint(equalTo: rendererHost.bottomAnchor)
        ])
    }

    @objc private func changeDisplayMode() {
        pausePlayback()
        let selected = shows3D ? renderer.selectedKeyID : spatialRenderer?.selectedKeyID
        if shows3D && spatialRenderer == nil {
            presented3DState = nil
            let spatial: GrowthKeyboard3DRenderer
            if usesMechanical {
                do {
                    let model = try MechanicalKeyboardScene()
                    try model.configureFullModel()
                    spatial = GrowthKeyboard3DRenderer(layout: renderer.sceneLayout,
                        renderFrame: { model.renderGrowth($0, background: $1) },
                        imageSize: MechanicalKeyboardScene.size,
                        usesTransparentCanvas: startsIn3D,
                        renderDetailedFrame: { model.renderGrowth($0, background: $1, pixelScale: $2) },
                        replaySceneFactory: { GrowthReplayPressScene(mechanical: model) })
                } catch {
                    usesMechanical = false
                    NSAlert(error: error).runModal()
                    changeDisplayMode()
                    return
                }
            } else {
                spatial = GrowthKeyboard3DRenderer(layout: renderer.sceneLayout,
                    usesTransparentCanvas: startsIn3D)
            }
            spatial.onReplayFailure = { [weak self] in
                guard let self else { return }
                self.pausePlayback(); self.renderSelection()
                self.coverageLabel.stringValue = self.text("replay.unreadable")
                self.notifySidebar()
            }
            spatial.onSelectionChanged = { [weak self] in self?.showKeyDetail($0) }
            installRenderer(spatial)
            spatialRenderer = spatial
        }
        renderer.clearHover()
        spatialRenderer?.clearHover()
        renderer.isHidden = shows3D
        spatialRenderer?.isHidden = !shows3D
        slider.isContinuous = !shows3D
        play.toolTip = shows3D ? text("growth.mode.3d.help") : nil
        renderSelection()
        if shows3D { spatialRenderer?.selectKey(selected) }
        else { renderer.selectKey(selected) }
        updateActive()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !view.isHiddenOrHasHiddenAncestor else { return }
        setPresented(true)
        if presentation == nil { refreshData(resetToToday: true) }
    }

    func setMechanical(_ enabled: Bool) {
        _ = view
        guard enabled != usesMechanical else { return }
        pausePlayback()
        let selected = spatialRenderer?.selectedKeyID ?? renderer.selectedKeyID
        spatialRenderer?.setActive(false)
        spatialRenderer?.removeFromSuperview()
        spatialRenderer = nil
        usesMechanical = enabled
        modeSelector.selectedSegment = 1
        changeDisplayMode()
        spatialRenderer?.selectKey(selected)
        updateControls()
    }
    override func viewWillDisappear() {
        super.viewWillDisappear()
        setPresented(false)
    }

    func setPresented(_ presented: Bool) {
        isPresented = presented
        if !isViewLoaded { return }
        if presented && shows3D && spatialRenderer == nil { changeDisplayMode() }
        bindWindow()
        updateActive()
        if !presented { renderer.clearHover() }
    }

    /// Closing releases GPU resources; temporary inactivity keeps the last complete frame.
    func releaseResourcesForClosedWindow() {
        isPresented = false
        pausePlayback()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        observedWindow = nil
        spatialRenderer?.setActive(false)
        spatialRenderer?.removeFromSuperview()
        spatialRenderer = nil
        presented3DState = nil
        presentation = nil
        example = nil
    }

    private var isWindowActive: Bool {
        guard isPresented, !view.isHiddenOrHasHiddenAncestor, let window = view.window else { return false }
        return window.isVisible && window.isKeyWindow && !window.isMiniaturized
            && window.occlusionState.contains(.visible) && NSApp.isActive
    }

    private func updateActive() {
        playback.waitsForPresentation = shows3D
        playback.replaysSingleDay = loadReplay != nil || isExample
        playback.stepInterval = shows3D ? 0.35 : 0.15
        playback.setActive(isWindowActive)
        spatialRenderer?.setActive(isWindowActive && shows3D)
        if !isWindowActive { cancelReplayLoad?(); cancelReplayLoad = nil; renderer.clearHover(); spatialRenderer?.clearHover() }
        updateControls()
    }

    private func bindWindow() {
        guard let window = view.window, observedWindow !== window else { return }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        observedWindow = window
        observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("Keytide.keyReplayRecordsDeleted"), object: nil, queue: .main) { [weak self] _ in
            self?.pausePlayback(); self?.renderSelection()
        })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in
                guard let self else { return }
                if name == NSWindow.didBecomeKeyNotification && self.isPresented {
                    self.refreshData(resetToToday: false)
                }
                if name == NSWindow.didResignKeyNotification || name == NSWindow.willCloseNotification {
                    self.cancelReplayLoad?(); self.cancelReplayLoad = nil
                    self.playback.setActive(false); self.spatialRenderer?.setActive(false)
                    self.renderer.clearHover(); self.updateControls()
                } else { self.updateActive() }
            })
        }
        for name in [NSApplication.didHideNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                guard let self else { return }
                if name == NSApplication.didBecomeActiveNotification {
                    self.updateActive()
                    if self.isWindowActive && self.shows3D { self.renderSelection() }
                } else {
                    self.cancelReplayLoad?(); self.cancelReplayLoad = nil
                    self.playback.setActive(false); self.spatialRenderer?.setActive(false)
                    self.renderer.clearHover(); self.updateControls()
                }
            })
        }
    }

    func refreshData(resetToToday: Bool = false) {
        _ = view
        let restoringDate = isExample ? nil : realDateBeforeExample
        let selectedDate = restoringDate ?? presentation.map { $0.date(at: playback.state.offset) }
        let wasToday = restoringDate == nil && scope == 0 && (presentation.map { playback.state.offset == $0.dayCount - 1 } ?? true)
        pausePlayback()
        if isExample {
            if example == nil { example = .make() }
            presentation = example?.presentation
        } else {
            presentation = loadPresentation()
            realDateBeforeExample = nil
        }
        guard let presentation else {
            presented3DState = nil
            renderer.apply([]); renderer.selectKey(nil)
            spatialRenderer?.apply([]); spatialRenderer?.selectKey(nil)
            displayedKeyUsages = []
            displayedMediaCounts = [:]
            dateLabel.stringValue = text("growth.empty")
            totalLabel.stringValue = ""
            coverageLabel.stringValue = text("growth.empty.detail")
            displayedMetricTitle = nil
            displayedScopeTitle = text("keyboard.mode.growth")
            notifySidebar()
            updateControls()
            return
        }
        datePicker.calendar = presentation.calendar
        datePicker.timeZone = presentation.calendar.timeZone
        datePicker.minDate = usesTimeline ? presentation.period.firstTrackedDate : nil
        rangeStartPicker.calendar = presentation.calendar
        rangeStartPicker.timeZone = presentation.calendar.timeZone
        rangeStartPicker.maxDate = presentation.today
        datePicker.maxDate = presentation.today
        dateFormatter.calendar = presentation.calendar; dateFormatter.timeZone = presentation.calendar.timeZone
        timelineStart.stringValue = dateFormatter.string(from: presentation.period.firstTrackedDate)
        timelineEnd.stringValue = text("growth.today")
        slider.minValue = 0; slider.maxValue = Double(max(1, presentation.dayCount - 1))
        let offset = resetToToday || wasToday ? presentation.dayCount - 1
            : selectedDate.map { presentation.offset(for: $0) } ?? presentation.dayCount - 1
        playback.reset(dayCount: presentation.dayCount, selectedOffset: offset)
        updateActive()
    }

    private func renderSelection() {
        guard let presentation else { updateControls(); return }
        selectionGeneration &+= 1
        cancelReplayLoad?(); cancelReplayLoad = nil
        let selectionToken = selectionGeneration
        let frame: GrowthKeyboardFrame
        if usesTimeline {
            frame = presentation.frame(at: playback.state.offset)
        } else {
            let end = inspectionDate ?? presentation.date(at: playback.state.offset)
            frame = presentation.intervalFrame(from: scope == 2 ? (rangeStart ?? end) : end, through: end)
        }
        if shows3D {
            let offset = playback.state.offset, generation = playback.presentationGeneration
            let playing = playback.isPresentingPlaybackFrame
            let apply: (GrowthReplayPressPlan) -> Void = { [weak self] plan in
                guard let self, self.selectionGeneration == selectionToken,
                      self.playback.presentationGeneration == generation else { return }
                let previous = self.usesTimeline && offset > 0 ? presentation.frame(at: offset - 1) : nil
                let from = previous?.keyUsages ?? frame.keyUsages.map { GrowthKeyboardKeyUsage(id: $0.id, count: 0) }
                self.spatialRenderer?.onReplayProgress = { [weak self] usages, count in
                    guard let self, self.selectionGeneration == selectionToken else { return }
                    self.displayedKeyUsages = usages
                    self.displayedMediaCounts = nil
                    self.updateLabels(for: frame)
                    let base = previous?.snapshot.totalKeyPresses ?? 0
                    self.totalLabel.stringValue = self.grouped(min(frame.snapshot.totalKeyPresses, base > Int.max - count ? Int.max : base + count))
                    self.coverageLabel.stringValue = self.text(self.isExample ? "replay.example.help" : "replay.coverage")
                    self.refreshSelectedKeyDetail()
                }
                let hasUnreadableChunks = plan.hasUnreadableChunks
                let hasRecordedEvents = plan.hasEvents
                self.spatialRenderer?.apply(frame.keyUsages, animated: playing,
                    replayFrom: playing ? from : nil,
                    recordedReplay: playing ? plan : nil) { [weak self] in
                    guard let self, self.shows3D, self.playback.state.offset == offset,
                          self.selectionGeneration == selectionToken else { return }
                    self.displayedKeyUsages = frame.keyUsages
                    self.displayedMediaCounts = frame.physical.mediaCounts
                    self.updateLabels(for: frame)
                    if playing && !self.isExample {
                        self.coverageLabel.stringValue += " · " + self.text(hasUnreadableChunks ? "replay.unreadable" : !hasRecordedEvents ? "replay.noDetails" : "replay.coverage")
                    }
                    self.presented3DState = Presented3DState(frame: frame,
                        date: self.dateLabel.stringValue, total: self.totalLabel.stringValue,
                        coverage: self.coverageLabel.stringValue, metric: self.metricTitle,
                        scope: self.displayedScopeTitle)
                    self.refreshSelectedKeyDetail()
                    self.playback.framePresented(at: offset, generation: generation)
                    self.updateControls()
                }
            }
            if playing, isExample {
                apply(GrowthReplayPressPlan(day: frame.dayKey == example?.recordedDayKey ? (example?.day ?? .empty) : .empty))
            } else if playing, let loadReplay {
                coverageLabel.stringValue = text("replay.loading")
                cancelReplayLoad = loadReplay(frame.dayKey) { [weak self] result in
                    guard let self, self.isWindowActive, self.selectionGeneration == selectionToken,
                          self.playback.presentationGeneration == generation else { return }
                    switch result {
                    case .success(let plan): apply(plan)
                    case .failure:
                        self.pausePlayback(); self.renderSelection()
                        self.coverageLabel.stringValue = self.text("replay.unreadable")
                        self.notifySidebar()
                    }
                }
            } else { apply(GrowthReplayPressPlan(day: .empty)) }
            updateControls()
        } else {
            renderer.apply(frame.keyUsages)
            displayedKeyUsages = frame.keyUsages
            displayedMediaCounts = frame.physical.mediaCounts
            updateLabels(for: frame)
            refreshSelectedKeyDetail()
        }
    }

    private func updateLabels(for frame: GrowthKeyboardFrame) {
        if let interval = frame.interval {
            displayedMetricTitle = text(scope == 1 ? "keyboard.scope.dayTotal" : "keyboard.scope.rangeTotal")
            displayedScopeTitle = text(scope == 1 ? "keyboard.scope.day" : "keyboard.scope.range")
            let first = dateFormatter.string(from: interval.start), last = dateFormatter.string(from: interval.end)
            var dateText = scope == 1 ? first : "\(first) – \(last)"
            if interval.missingDays > 0 {
                dateText += " · " + String(format: text("keyboard.scope.missingShort"), interval.recordedDays, interval.expectedDays)
            }
            if interval.hasPartialDetails { dateText += " · " + text("keyboard.scope.partialShort") }
            set(dateLabel, dateText)
            set(totalLabel, interval.recordedDays == 0 ? "—" : grouped(frame.snapshot.totalKeyPresses))
            var note = text("keyboard.scope.participation")
            if interval.missingDays > 0 {
                note += "  " + String(format: text("keyboard.scope.missing"), interval.recordedDays, interval.expectedDays)
            }
            if interval.hasPartialDetails { note += "  " + text("keyboard.scope.partial") }
            set(coverageLabel, note)
            inspectionDate = interval.end
            rangeStart = interval.start
            datePicker.dateValue = interval.end
            rangeStartPicker.dateValue = interval.start
            updateControls()
            return
        }
        displayedMetricTitle = text(isExample ? "replay.example.metric" : "growth.metric.caption")
        displayedScopeTitle = text(isExample ? "replay.example.scope" : "keyboard.mode.growth")
        set(dateLabel, isExample ? String(format: text("replay.example.summary"), frame.dayIndex)
            : String(format: text("growth.date.summary"), dateFormatter.string(from: frame.date), frame.dayIndex))
        set(totalLabel, grouped(frame.snapshot.totalKeyPresses))
        var note = frame.hasPartialDetails
            ? String(format: text("growth.coverage"), grouped(frame.snapshot.detailedKeyPresses), grouped(frame.snapshot.totalKeyPresses))
            : text("growth.participation")
        if frame.dayKey != frame.snapshot.dayKey { note += "  " + text("growth.noDailyRecord") }
        if isExample { note = text("replay.example.help") }
        set(coverageLabel, note)
        datePicker.dateValue = frame.date
        slider.integerValue = playback.state.offset
        updateControls()
    }

    func exportCurrentImage() -> (image: NSImage, summary: String, coverage: String)? {
        pausePlayback()
        updateControls()
        guard presentation != nil, shows3D, let state = presented3DState,
              let image = spatialRenderer?.exportImage() else {
            renderSelection()
            return nil
        }
        // Cancelling restores the renderer's last complete image. Restore its
        // matching summary and details too, rather than exporting replay progress.
        displayedKeyUsages = state.frame.keyUsages
        displayedMediaCounts = state.frame.physical.mediaCounts
        dateLabel.stringValue = state.date
        totalLabel.stringValue = state.total
        coverageLabel.stringValue = state.coverage
        displayedMetricTitle = state.metric
        displayedScopeTitle = state.scope
        refreshSelectedKeyDetail()
        // Export uses the last complete frame. Finish the currently requested
        // date without replay so cancelling does not strand its controls and
        // summary on different dates, or leave a cold first render cancelled.
        renderSelection()
        return (image, "\(state.date) · \(state.total) \(state.metric)", state.coverage)
    }

    private func pausePlayback() {
        cancelReplayLoad?(); cancelReplayLoad = nil
        selectionGeneration &+= 1
        playback.pause()
        spatialRenderer?.cancelReplayAnimation()
    }

    private func updateControls() {
        let cumulative = usesTimeline
        play.isHidden = scope == 2
        slider.isHidden = !cumulative
        previous.isHidden = scope == 2
        next.isHidden = scope == 2
        rangeStartPicker.isHidden = scope != 2
        rangeSeparator.isHidden = scope != 2
        datePicker.setAccessibilityLabel(text(scope == 2 ? "keyboard.scope.end" : "growth.date"))
        let available = presentation != nil
        previous.isEnabled = available && (!cumulative || playback.state.offset > 0)
        next.isEnabled = available && (cumulative ? playback.state.offset < playback.state.lastOffset : (inspectionDate ?? Date()) < (presentation?.today ?? Date()))
        datePicker.isEnabled = available && !isExample
        refresh.isEnabled = !isExample
        slider.isEnabled = available && (presentation?.dayCount ?? 0) > 1
        play.isEnabled = scope != 2 && available && ((presentation?.dayCount ?? 0) > 1 || loadReplay != nil)
        today.isEnabled = available
        today.title = text(isExample ? "replay.example.return" : "growth.today")
        today.toolTip = isExample ? text("replay.example.returnHelp") : nil
        play.title = text(isPlaybackRunning ? "growth.pause" : isExample ? "replay.example.play" : scope == 1 ? "replay.playDay" : "growth.play")
        play.image = NSImage(systemSymbolName: isPlaybackRunning ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        play.setAccessibilityLabel(play.title)
    }
    private func select(_ offset: Int) {
        if !isExample, let presentation, offset >= presentation.dayCount - 1,
           playback.state.offset < presentation.dayCount - 1 {
            refreshData(resetToToday: true)
        } else { playback.select(offset) }
    }
    @objc private func previousDay() { moveDay(-1) }
    @objc private func nextDay() { moveDay(1) }
    private func moveDay(_ delta: Int) {
        guard !usesTimeline, let presentation else { select(playback.state.offset + delta); return }
        inspectionDate = presentation.calendar.date(byAdding: .day, value: delta, to: inspectionDate ?? presentation.today)
        renderSelection()
    }
    @objc private func showToday() {
        if isExample { scopeSelector.selectItem(at: realScopeBeforeExample); changeScope(); return }
        if scope != 0 { inspectionDate = Calendar.current.startOfDay(for: Date()) }
        refreshData(resetToToday: true)
    }
    @objc private func changeScope() {
        pausePlayback()
        if isExample || previousScope == 3 {
            if isExample {
                if previousScope != 3 {
                    realScopeBeforeExample = previousScope
                    realDateBeforeExample = previousScope == 0
                        ? presentation.map { $0.date(at: playback.state.offset) } : inspectionDate
                }
                example = .make()
            }
            previousScope = scope
            refreshData(resetToToday: isExample)
            return
        }
        guard let presentation else { updateControls(); return }
        if previousScope == 0 { inspectionDate = presentation.date(at: playback.state.offset) }
        inspectionDate = inspectionDate ?? presentation.date(at: playback.state.offset)
        previousScope = scope
        if scope == 2, let start = rangeStart, start > inspectionDate! {
            rangeStart = inspectionDate
        }
        if scope == 2, rangeStart == nil {
            rangeStart = presentation.calendar.date(byAdding: .day, value: -6, to: inspectionDate!)
        }
        datePicker.minDate = scope == 0 ? presentation.period.firstTrackedDate : nil
        if scope == 0 { playback.select(presentation.offset(for: inspectionDate!)) }
        else { renderSelection() }
        updateControls()
    }
    @objc private func pickRangeStart() {
        rangeStart = rangeStartPicker.dateValue
        if let end = inspectionDate, rangeStart! > end { inspectionDate = rangeStart }
        pausePlayback(); renderSelection()
    }

    func showDay(_ date: Date) {
        _ = view
        scopeSelector.selectItem(at: 1)
        previousScope = 1
        inspectionDate = date
        rangeStart = nil
        refreshData(resetToToday: false)
    }
    @objc private func refreshToday() { refreshData() }
    @objc private func pickDate() {
        guard let presentation else { return }
        if scope == 0 { select(presentation.offset(for: datePicker.dateValue)) }
        else {
            inspectionDate = datePicker.dateValue
            if let start = rangeStart, start > datePicker.dateValue { rangeStart = datePicker.dateValue }
            pausePlayback(); renderSelection()
        }
    }
    @objc private func scrub() { select(slider.integerValue) }
    @objc private func togglePlayback() {
        guard scope != 2 else { return }
        if isPlaybackRunning { pausePlayback(); renderSelection() }
        else {
            updateActive()
            if scope == 1, let presentation {
                playback.select(presentation.offset(for: inspectionDate ?? presentation.today))
                playback.playSelection()
            } else { playback.start() }
        }
    }

    func showExample() {
        _ = view
        if scope != 3 {
            scopeSelector.selectItem(at: 3)
            changeScope()
        }
    }
    private func showKeyDetail(_ value: GrowthKeyboardKeyUsage?) {
        guard let value else {
            spatialRenderer?.setAccessibilityValue(nil)
            renderer.setAccessibilityValue(nil)
            onSelectionChanged?(nil)
            return
        }
        let insight = GrowthKeyboardKeyInsight(id: value.id, in: displayedKeyUsages)
        let rank = insight.rank.map { String(format: text("growth.key.rank"), $0) }
            ?? text("growth.key.unranked")
        let accessibility = String(format: text("growth.key.accessibility"), displayName(value.id),
            insight.usage.count, insight.share * 100, rank)
            + (mediaBreakdown(for: value.id, total: value.count).map { "; " + $0 } ?? "")
        notifySidebar()
        spatialRenderer?.setAccessibilityValue(accessibility)
        renderer.setAccessibilityValue(accessibility)
    }

    private func notifySidebar() {
        onSummaryChanged?(totalLabel.stringValue, dateLabel.stringValue, coverageLabel.stringValue)
        onSelectionChanged?(currentSidebarSelection())
    }

    private func currentSidebarSelection() -> GrowthKeyboardSidebarSelection? {
        let id = shows3D ? spatialRenderer?.selectedKeyID : renderer.selectedKeyID
        guard let id, !displayedKeyUsages.isEmpty else { return nil }
        let insight = GrowthKeyboardKeyInsight(id: id, in: displayedKeyUsages)
        return GrowthKeyboardSidebarSelection(name: displayName(id), countValue: insight.usage.count,
            count: grouped(insight.usage.count),
            share: insight.share,
            rank: insight.rank.map { String(format: text("growth.key.rank"), $0) },
            mediaBreakdown: mediaBreakdown(for: id, total: insight.usage.count))
    }

    private func mediaBreakdown(for id: String, total: Int) -> String? {
        if ["F3", "F4", "F5", "F6"].contains(id) { return text("growth.key.systemActionUnavailable") }
        guard PhysicalKeyMapping.hasMediaDisplayKey(id), let displayedMediaCounts else { return nil }
        let media = displayedMediaCounts[id, default: 0]
        return String(format: text("growth.key.mediaBreakdown"), grouped(max(0, total - media)), grouped(media))
    }

    private func refreshSelectedKeyDetail() {
        let id = shows3D ? spatialRenderer?.selectedKeyID : renderer.selectedKeyID
        let value = id.flatMap { key in displayedKeyUsages.first { $0.id == key } }
        showKeyDetail(value)
        if value == nil { notifySidebar() }
    }
    private func displayName(_ id: String) -> String {
        let names = ["LeftCmd", "RightCmd", "LeftShift", "RightShift", "LeftOption", "RightOption", "Ctrl",
                     "Return", "Delete", "Space", "CapsLock", "Tab", "Esc", "Fn", "Left", "Right", "Up", "Down"]
        return names.contains(id) ? text("growth.key." + id) : id
    }
    private func grouped(_ count: Int) -> String { numberFormatter.string(from: NSNumber(value: count)) ?? "\(count)" }
    private func set(_ label: NSTextField, _ value: String) { if label.stringValue != value { label.stringValue = value } }
    private func text(_ key: String) -> String { NSLocalizedString(key, comment: "Growth Keyboard") }
}
