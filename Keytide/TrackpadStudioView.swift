import Cocoa

/// Replaceable brush; receives normalized contacts, independent of private API.
private final class TrackpadInkView: NSView {
    struct Point { let position: CGPoint; let time: Double; let pressure: CGFloat }
    private var trails: [Int32: [Point]] = [:]
    private var lastSourceTime: Double?
    private var touching = Set<Int32>()
    private var cursorHidden = false
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard window?.isKeyWindow == true, NSApp.isActive else { return }
        if !cursorHidden {
            // Freeze the pointer at the click inside the canvas. Hiding alone
            // still lets physical motion send clicks to other applications.
            guard CGAssociateMouseAndMouseCursorPosition(0) == .success else { NSSound.beep(); return }
            NSCursor.hide(); cursorHidden = true
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { restoreCursor(); window?.makeFirstResponder(nil) }
        else { super.keyDown(with: event) }
    }
    private func restoreCursor() {
        if cursorHidden { _ = CGAssociateMouseAndMouseCursorPosition(1); NSCursor.unhide(); cursorHidden = false }
    }
    var stardust = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel(NSLocalizedString("trackpad.canvas", comment: ""))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if cursorHidden { _ = CGAssociateMouseAndMouseCursorPosition(1); NSCursor.unhide() } }
    override func resignFirstResponder() -> Bool { restoreCursor(); return super.resignFirstResponder() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        restoreCursor(); super.viewWillMove(toWindow: newWindow)
    }
    func clear() {
        restoreCursor(); trails.removeAll(); touching.removeAll(); lastSourceTime = nil; needsDisplay = true
    }
    func accept(_ frame: TrackpadFrame) {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastSourceTime, frame.sourceTime < lastSourceTime || frame.sourceTime - lastSourceTime > 0.25 { trails.removeAll(); touching.removeAll() }
        lastSourceTime = frame.sourceTime
        var active = Set<Int32>()
        for contact in frame.contacts {
            guard contact.state == 3 || contact.state == 4 else { continue }
            active.insert(contact.identity)
            if contact.state == 3 { trails[contact.identity] = nil }
            let raw = max(0, Double(contact.rawPressure ?? 0))
            // Bounded relative response; not calibrated force or a click detector.
            let pressure = CGFloat(raw / (raw + 60))
            trails[contact.identity, default: []].append(Point(position: contact.position, time: now, pressure: pressure))
            if let points = trails[contact.identity], points.count > 4096 {
                // The 4,097th point triggers compaction. Both endpoints have even indices.
                trails[contact.identity] = stride(from: 0, to: points.count, by: 2).map { points[$0] }
            }
        }
        for id in touching where !active.contains(id) { trails[id] = nil }
        touching = active
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let surface = bounds.insetBy(dx: 16, dy: 16)
        NSColor.white.withAlphaComponent(0.035).setFill()
        let outline = NSBezierPath(roundedRect: surface, xRadius: 24, yRadius: 24)
        outline.fill(); NSColor.white.withAlphaComponent(0.2).setStroke(); outline.lineWidth = 1; outline.stroke()
        NSGraphicsContext.saveGraphicsState(); outline.addClip()
        func position(_ p: CGPoint) -> CGPoint { CGPoint(x: surface.minX + p.x * surface.width, y: surface.minY + p.y * surface.height) }
        for points in trails.values where !points.isEmpty {
            let alpha: CGFloat = 0.55 + points.last!.pressure * 0.45
            let color = NSColor.systemCyan.withAlphaComponent(alpha)
            color.setStroke(); color.setFill()
            // One continuous quadratic path avoids overdraw at every sample joint.
            let path = NSBezierPath()
            // A short moving average responds to current pressure instead of
            // diluting it over the entire stroke. Keep one joined path.
            let recent = points.suffix(8)
            let pressure = recent.reduce(CGFloat(0)) { $0 + $1.pressure } / CGFloat(recent.count)
            path.lineWidth = 2.0 + pressure * 3.5
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: position(points[0].position))
            var start = position(points[0].position)
            for index in 1..<points.count {
                let control = position(points[index - 1].position), next = position(points[index].position)
                let end = index == points.count - 1 ? next : CGPoint(x: (control.x + next.x)/2, y: (control.y + next.y)/2)
                path.curve(to: end, controlPoint1: CGPoint(x: start.x + (control.x-start.x)*2/3, y: start.y + (control.y-start.y)*2/3),
                    controlPoint2: CGPoint(x: end.x + (control.x-end.x)*2/3, y: end.y + (control.y-end.y)*2/3))
                start = end
            }
            NSColor.systemCyan.withAlphaComponent(0.78 + pressure * 0.18).setStroke(); path.stroke()
            if stardust && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                for (index, point) in points.enumerated() where index % 4 == 0 {
                    let p = position(point.position), angle = Double(index) * 2.4
                    NSColor.systemYellow.withAlphaComponent(alpha * 0.65).setFill()
                    NSBezierPath(ovalIn: NSRect(x: p.x + cos(angle) * 9, y: p.y + sin(angle) * 9, width: 2.5, height: 2.5)).fill()
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class TrackpadStudioView: NSView {
    struct Choices {
        let stardust: Bool
        let haptics: NSControl.StateValue
        let replayDate: Date
    }

    var choices: Choices { Choices(stardust: ink.stardust, haptics: haptics.state, replayDate: day.dateValue) }

    private let service = TrackpadAppService.shared
    private let ink = TrackpadInkView()
    private let replay = NSButton()
    private let day = NSDatePicker()
    private var playback: DispatchWorkItem?
    private var replayGeneration = 0
    private var replayReader: TrackpadReplayReader?
    private var replayLoad: (() -> Void)?
    private let status = NSTextField(wrappingLabelWithString: "")
    private let help = NSTextField(wrappingLabelWithString: "")
    private let haptics = NSButton(checkboxWithTitle: NSLocalizedString("trackpad.haptics", comment: ""), target: nil, action: nil)
    private var presented = false
    private var workspaceSuspensions = Set<Notification.Name>()
    private var lastHaptic = -Double.infinity
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private func text(_ key: String) -> String { NSLocalizedString(key, comment: "Trackpad preview") }
    init(restoring choices: Choices?) {
        super.init(frame: .zero)
        let brush = NSSegmentedControl(labels: [text("trackpad.ink"), text("trackpad.stardust")], trackingMode: .selectOne, target: self, action: #selector(changeBrush(_:)))
        ink.stardust = choices?.stardust ?? false
        haptics.state = choices?.haptics ?? .off
        brush.selectedSegment = ink.stardust ? 1 : 0
        brush.setAccessibilityLabel(text("trackpad.brush"))
        let clear = NSButton(title: text("trackpad.clear"), target: self, action: #selector(clearInk)); clear.bezelStyle = .rounded
        replay.title = text("trackpad.replay"); replay.bezelStyle = .rounded
        replay.target = self; replay.action = #selector(playDay)
        day.datePickerElements = [.yearMonthDay]; day.datePickerStyle = .textFieldAndStepper
        let now = Date()
        day.maxDate = now
        day.dateValue = min(choices?.replayDate ?? now, now)
        let toolbar = NSStackView(views: [brush, clear, haptics, day, replay]); toolbar.spacing = 8
        help.stringValue = text("trackpad.preview.help"); help.font = .systemFont(ofSize: 12)
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.stringValue = text("trackpad.ready")
        for child in [toolbar, help, ink, status] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            toolbar.centerXAnchor.constraint(equalTo: centerXAnchor), toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            help.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12), help.centerXAnchor.constraint(equalTo: centerXAnchor),
            help.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
        ink.translatesAutoresizingMaskIntoConstraints = true
        service.onFrame = { [weak self] frame in
            guard let self, self.playback == nil, self.canPreview else { return }
            self.ink.accept(frame)
            if self.service.failed || self.service.recording { self.updateRecordingUI() }
            else { self.status.stringValue = String(format: self.text("trackpad.live"), frame.contacts.filter { $0.state == 3 || $0.state == 4 }.count, frame.sourceTime) }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.workspaceSuspensions.insert(name); self?.refreshActivity()
            }))
        }
        for (name, suspension) in [(NSWorkspace.didWakeNotification, NSWorkspace.willSleepNotification),
                                   (NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification)] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.workspaceSuspensions.remove(suspension); self?.refreshActivity()
            }))
        }
        let nc = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     .NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append((nc, nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshActivity() }))
        }
        observers.append((nc, nc.addObserver(forName: TrackpadAppService.didChange, object: nil, queue: .main) { [weak self] notification in
            guard let self, notification.object as? TrackpadAppService === self.service else { return }
            if self.service.deleting { self.suspendRendering() }
            else { self.refreshActivity() }
        }))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { observers.forEach { $0.0.removeObserver($0.1) }; playback?.cancel(); replayLoad?(); replayReader?.cancel() }
    override func layout() {
        super.layout()
        let bottom = status.frame.maxY + 8
        let available = max(0, help.frame.minY - 12 - bottom)
        let width = min(850, bounds.width * 0.90, available / 0.62)
        let height = width * 0.62
        ink.frame = NSRect(x: (bounds.width - width) / 2, y: bottom + (available - height) / 2,
                           width: width, height: height)
    }
    private var canPreview: Bool {
        guard presented, !service.deleting, workspaceSuspensions.isEmpty, !isHiddenOrHasHiddenAncestor,
              let window else { return false }
        return window.isVisible && window.isKeyWindow && !window.isMiniaturized
            && window.occlusionState.contains(.visible) && NSApp.isActive && !NSApp.isHidden
    }
    func setPresented(_ value: Bool) { presented = value; refreshActivity() }
    func suspendRendering() {
        cancelReplay(); ink.clear()
        service.setPreview(false); updateRecordingUI()
    }
    func refreshActivity() {
        let now = Date()
        day.maxDate = now
        if day.dateValue > now { day.dateValue = now }
        let active = canPreview
        if !active { cancelReplay(); ink.clear() }
        service.setPreview(active && playback == nil)
        updateRecordingUI()
    }
    private func cancelReplay() {
        replayGeneration += 1
        replayLoad?(); replayLoad = nil
        replayReader?.cancel(); replayReader = nil
        playback?.cancel(); playback = nil
    }
    private func updateRecordingUI() {
        replay.isEnabled = !service.deleting; day.isEnabled = !service.deleting
        let key: String
        if service.failed { key = "trackpad.failed" }
        else if playback != nil { key = "trackpad.replay" }
        else if service.suspended { key = "trackpad.helper.suspended" }
        else if service.recording { key = "trackpad.helper.recording" }
        else if !service.isAvailable { key = "trackpad.helper.unavailable" }
        else { key = canPreview ? "trackpad.waiting" : "trackpad.ready" }
        status.stringValue = text(key)
    }
    private func acceptsReplay(_ token: Int) -> Bool {
        guard token == replayGeneration else { return false }
        guard canPreview else { refreshActivity(); return false }
        return true
    }
    @objc private func playDay() {
        guard canPreview else { return }
        cancelReplay(); let token = replayGeneration
        playback = DispatchWorkItem {}; ink.clear(); service.setPreview(false); updateRecordingUI()
        replayLoad = service.load(day: day.dateValue) { [weak self] reader in
            guard let self, self.acceptsReplay(token) else { reader?.cancel(); return }
            self.replayLoad = nil
            guard let reader else {
                self.playback = nil; self.refreshActivity()
                if !self.service.failed { self.status.stringValue = self.text("trackpad.replay.empty") }
                return
            }
            self.replayReader = reader
            let start = ProcessInfo.processInfo.systemUptime
            func tick() {
                guard self.acceptsReplay(token) else { reader.cancel(); return }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                reader.take(through: elapsed) { [weak self] frames, done, failed in
                    guard let self, self.acceptsReplay(token) else { reader.cancel(); return }
                    for frame in frames { self.ink.accept(frame) }
                    if done || failed {
                        self.playback = nil; self.replayReader = nil
                        self.refreshActivity()
                        if failed { self.status.stringValue = self.text("trackpad.failed") }
                        return
                    }
                    let work = DispatchWorkItem(block: tick); self.playback = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + (frames.count >= 128 ? 0 : 1.0/60), execute: work)
                }
            }
            tick()
        }
    }
    @objc private func changeBrush(_ sender: NSSegmentedControl) { ink.stardust = sender.selectedSegment == 1; feedback() }
    @objc private func clearInk() { ink.clear(); feedback() }
    private func feedback() {
        let now = ProcessInfo.processInfo.systemUptime
        guard haptics.state == .on, NSApp.isActive, window?.isKeyWindow == true, now - lastHaptic >= 0.25 else { return }
        lastHaptic = now
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// The UI asks the Helper to capture, record, and delete. It reads the existing
/// authenticated file format for display after a Helper flush barrier.
final class TrackpadAppService {
    static let shared = TrackpadAppService()
    static let didChange = Notification.Name("Keytide.trackpadAppServiceChanged")
    private let helper = HelperXPCClient.shared
    private var requestedPreview = false
    private var submittedPreview: Bool?
    private var status: TrackpadRecordingStatus = .off
    private(set) var isAvailable = false
    private(set) var changing = false
    private(set) var deleting = false
    var canChangeRecording: Bool { isAvailable && !changing && !deleting }
    var recording: Bool { status == .recording || status == .suspended }
    var failed: Bool { status == .failed }
    var suspended: Bool { status == .suspended }
    var recordingStatusKey: String {
        if changing { return "trackpad.record.starting" }
        if !isAvailable { return "trackpad.helper.unavailable" }
        switch status {
        case .off: return "trackpad.record.off"
        case .recording: return "trackpad.helper.recording"
        case .failed: return "trackpad.failed"
        case .suspended: return "trackpad.helper.suspended"
        }
    }
    var onFrame: ((TrackpadFrame) -> Void)?

    private init() {
        helper.addStateObserver { [weak self] state in
            DispatchQueue.main.async { [weak self] in self?.connectionChanged(state) }
        }
    }

    func setPreview(_ enabled: Bool) {
        requestedPreview = enabled
        reconcilePreview()
    }

    func receivePreview(_ frames: [TrackpadFrame]) {
        guard isAvailable, requestedPreview, let onFrame else { return }
        for frame in frames { onFrame(frame) }
    }

    func receiveStatus(_ status: TrackpadRecordingStatus) {
        guard isAvailable, self.status != status else { return }
        self.status = status
        publish()
    }

    private func connectionChanged(_ state: HelperXPCClient.State) {
        guard helper.state == state else { return }
        let supported: Bool
        if case .connected(let version, _) = state { supported = version >= HelperLocations.inputOwnershipVersion }
        else { supported = false }
        guard supported != isAvailable else { return }
        isAvailable = supported
        submittedPreview = nil
        if supported {
            send(.status) { _, _ in }
            reconcilePreview()
        } else {
            status = .off
        }
        publish()
    }

    private func reconcilePreview() {
        guard isAvailable else { return }
        if submittedPreview == nil, !requestedPreview { return }
        guard submittedPreview != requestedPreview else { return }
        let requested = requestedPreview
        submittedPreview = requested
        send(requested ? .startPreview : .stopPreview) { [weak self] _, ok in
            guard let self, self.submittedPreview == requested, !ok else { return }
            self.submittedPreview = nil
        }
    }

    func setRecording(_ enabled: Bool, completion: ((Bool) -> Void)? = nil) {
        guard canChangeRecording else { completion?(false); return }
        changing = true
        publish()
        send(enabled ? .enable : .disable) { [weak self] _, ok in
            self?.changing = false
            self?.publish()
            completion?(ok)
        }
    }

    func deleteAll(completion: @escaping (Bool) -> Void) {
        guard canChangeRecording else { completion(false); return }
        deleting = true
        setPreview(false)
        publish()
        send(.delete) { [weak self] _, ok in
            self?.deleting = false
            self?.publish()
            completion(ok)
        }
    }

    func load(day: Date, completion: @escaping (TrackpadReplayReader?) -> Void) -> () -> Void {
        var cancelled = false
        var localLoad: TrackpadReplayLoad?
        let read: () -> Void = {
            guard !cancelled else { return }
            localLoad = TrackpadReplayLibrary.load(day: day, completion: completion)
        }
        if isAvailable { send(.flush) { _, _ in read() } }
        else { read() }
        return { cancelled = true; localLoad?.cancel() }
    }

    private func send(_ command: TrackpadControl, completion: @escaping (TrackpadRecordingStatus?, Bool) -> Void) {
        helper.controlTrackpad(command) { [weak self] status, ok in
            DispatchQueue.main.async {
                if let status { self?.receiveStatus(status) }
                completion(status, ok)
            }
        }
    }

    private func publish() { NotificationCenter.default.post(name: Self.didChange, object: self) }
}
