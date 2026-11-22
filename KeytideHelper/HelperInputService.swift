import AppKit

/// The one live writer of existing local statistics and keyboard replay files.
/// All input ingress and control are serialized on the Helper main run loop.
final class HelperInputService {
    private let defaults: UserDefaults
    private let marker: URL
    private let tap: InputEventTap
    private let keyboard: HelperKeyReplayWriter
    private let sendThreshold: (StatsManager.ThresholdMetric, Int, Int) -> Void
    private var statsStorage: StatsManager?
    private var stats: StatsManager {
        if let statsStorage { return statsStorage }
        let manager = StatsManager(environment: .init(userDefaults: defaults, now: Date.init, calendar: { .current },
            makeDateKeyFormatter: {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                return formatter
            }, notificationCenter: .default, schedulesAutomaticWork: true,
            sendThresholdNotification: sendThreshold), batchesCaptureUpdates: true)
        statsStorage = manager
        return manager
    }
    private lazy var aggregator: InputEventAggregator = {
        let aggregator = InputEventAggregator(stats: stats)
        aggregator.onReplay = { [weak keyboard] time, code, phase, keys in
            keyboard?.receive(time: time, keyCode: code, phase: phase, growthKeys: keys)
        }
        aggregator.onReplayGap = { [weak keyboard] in keyboard?.captureGap() }
        return aggregator
    }()
    private let outputQueue = DispatchQueue(label: "Keytide.CapturePresentation", qos: .utility)
    private let importQueue = DispatchQueue(label: "Keytide.CaptureImport", qos: .utility)
    private var observers: [NSObjectProtocol] = []
    private var suspensions = Set<Notification.Name>()
    private var subscription: UUID?
    private var publishing = 0
    private var lastPublishedDay: Date?
    private var encodingSnapshot = false
    private var snapshotPending = false
    private var fullSnapshotPending = false
    private var loginRetry: DispatchWorkItem?
    private var calibrationReply: ((Data?, Bool) -> Void)?
    private var calibrationGeneration = 0
    private(set) var connected = false
    private var monitoringRequested = false
    private(set) var allowed = false
    private(set) var listening = false
    weak var sink: EventPayloadSink?
    var onKeepAlive: ((Bool) -> Void)?
    var onPresenceChange: ((Bool, Bool) -> Void)?
    var onSnapshot: ((Data) -> Void)?
    var onReplayStatus: ((TrackpadRecordingStatus) -> Void)?

    init(tap: InputEventTap, defaults: UserDefaults, marker: URL = HelperLocations.inputBackgroundMarker,
         keyboard: HelperKeyReplayWriter? = nil,
         sendThreshold: @escaping (StatsManager.ThresholdMetric, Int, Int) -> Void = { _, _, _ in }) {
        self.tap = tap; self.defaults = defaults; self.marker = marker
        self.sendThreshold = sendThreshold
        let keyboard = keyboard ?? HelperKeyReplayWriter(defaults: defaults)
        self.keyboard = keyboard
        keyboard.statusChanged = { [weak self] status in
            self?.tap.setReplayRecordingEnabled(status == .recording)
            self?.onReplayStatus?(status)
        }
    }

    func restore() {
        allowed = BackgroundInputPreference.isEnabled(in: defaults)
            && defaults.bool(forKey: BackgroundInputPreference.appliedKey)
            && (try? Data(contentsOf: marker)) == Data([1])
        if !allowed { try? removeMarker() }
        onKeepAlive?(allowed)
        onPresenceChange?(false, allowed)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.suspensions.insert(name)
                _ = self.updateTap()
            })
        }
        for (name, suspension) in [(NSWorkspace.didWakeNotification, NSWorkspace.willSleepNotification),
                                   (NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if self.suspensions.remove(suspension) != nil { _ = self.updateTap() }
            })
        }
        guard allowed else { return }
        if updateTap() == HelperErrorCode.accessibilityDenied {
            // launchd can start the Helper just before TCC is ready in an Aqua session.
            let retry = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.loginRetry = nil
                if self.allowed && !self.listening { _ = self.updateTap() }
            }
            loginRetry = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: retry)
        }
    }

    deinit {
        loginRetry?.cancel()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    func attachForPresentation() {
        if !connected {
            connected = true
            subscription = stats.addStatsUpdateHandler { [weak self] in self?.publish() }
            publish(full: true)
            onPresenceChange?(true, allowed)
        }
    }

    func attach() -> Int {
        attachForPresentation()
        monitoringRequested = true
        loginRetry?.cancel()
        loginRetry = nil
        return updateTap()
    }

    func detach() {
        connected = false
        monitoringRequested = false
        publishing &+= 1
        snapshotPending = false
        fullSnapshotPending = false
        if let subscription { stats.removeStatsUpdateHandler(subscription) }
        subscription = nil
        cancelCalibration()
        if allowed, !BackgroundInputPreference.isEnabled(in: defaults), setBackgroundAllowed(false) { return }
        _ = updateTap()
        onPresenceChange?(false, allowed)
    }

    func receive(_ payload: [String: Any]) {
        if listening { aggregator.receiveEvent(payload) }
    }

    func finish() {
        loginRetry?.cancel()
        tap.stop()
        keyboard.finish()
        statsStorage?.flushPendingSave()
    }

    @discardableResult
    private func updateTap() -> Int {
        guard (monitoringRequested || allowed), suspensions.isEmpty, let sink else {
            cancelCalibration()
            tap.stop()
            listening = false
            keyboard.suspend()
            if let statsStorage {
                aggregator.resetTransientInput()
                statsStorage.persistCaptureState()
            }
            return HelperErrorCode.none
        }
        let code = tap.start(sink: sink)
        let wasListening = listening
        listening = code == HelperErrorCode.none || code == HelperErrorCode.alreadyMonitoring
        if listening && !wasListening && keyboard.consent { keyboard.setEnabled(true, interactive: false) }
        if !listening && wasListening { keyboard.suspend() }
        return code
    }

    private func removeMarker() throws {
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
    }

    private func setBackgroundAllowed(_ value: Bool) -> Bool {
        do {
            if value {
                guard listening else { return false }
                try Data([1]).write(to: marker, options: .atomic)
            } else { try removeMarker() }
        } catch { return false }
        allowed = value
        defaults.set(value, forKey: BackgroundInputPreference.appliedKey)
        onKeepAlive?(value)
        _ = updateTap()
        onPresenceChange?(connected, allowed)
        if !value {
            loginRetry?.cancel()
            loginRetry = nil
        }
        return true
    }

    private func publish(full: Bool = false) {
        guard connected, let onSnapshot else { return }
        if encodingSnapshot {
            snapshotPending = true
            fullSnapshotPending = fullSnapshotPending || full
            return
        }
        let day = stats.displayCurrentStats().date
        let historyChanged = day != lastPublishedDay
        lastPublishedDay = day
        let snapshot = stats.captureSnapshot(includingHistory: full || historyChanged)
        let token = publishing
        encodingSnapshot = true
        outputQueue.async { [weak self] in
            let data = try? JSONEncoder().encode(snapshot)
            DispatchQueue.main.async {
                guard let self else { return }
                self.encodingSnapshot = false
                if self.connected, self.publishing == token, let data { onSnapshot(data) }
                if self.snapshotPending {
                    let needsHistory = self.fullSnapshotPending
                    self.snapshotPending = false
                    self.fullSnapshotPending = false
                    self.publish(full: needsHistory)
                }
            }
        }
    }

    func control(_ command: InputControl, argument: Data, reply: @escaping (Data?, Bool) -> Void) {
        func backgroundReply(_ ok: Bool) {
            reply(try? JSONEncoder().encode(BackgroundInputStatus(allowed: allowed, listening: listening)), ok)
        }
        switch command {
        case .backgroundStatus: backgroundReply(true)
        case .enableBackground: backgroundReply(setBackgroundAllowed(true))
        case .disableBackground: backgroundReply(setBackgroundAllowed(false))
        case .resetStats:
            stats.resetStats()
            publish(full: true)
            reply(nil, true)
        case .mergeStats, .overwriteStats:
            importQueue.async { [weak self] in
                let prepared = try? StatsManager.prepareStatsImport(from: argument)
                DispatchQueue.main.async {
                    guard let self, let prepared else { reply(nil, false); return }
                    self.stats.applyPreparedImport(prepared, mode: command == .mergeStats ? .merge : .overwrite)
                    self.publish(full: true)
                    reply(nil, true)
                }
            }
        case .updateAttribution:
            guard let enabled = try? JSONDecoder().decode(Bool.self, from: argument) else { reply(nil, false); return }
            if stats.appStatsEnabled != enabled { stats.appStatsEnabled = enabled }
            reply(nil, true)
        case .updateThresholdPreferences:
            guard let preferences = try? JSONDecoder().decode(InputThresholdPreferences.self, from: argument),
                  preferences.keyPresses >= 0, preferences.clicks >= 0 else { reply(nil, false); return }
            if stats.keyPressNotifyThreshold != preferences.keyPresses { stats.keyPressNotifyThreshold = preferences.keyPresses }
            if stats.clickNotifyThreshold != preferences.clicks { stats.clickNotifyThreshold = preferences.clicks }
            if stats.notificationsEnabled != preferences.enabled { stats.notificationsEnabled = preferences.enabled }
            reply(nil, true)
        case .enableKeyboardReplay, .disableKeyboardReplay, .keyboardReplayStatus, .flushKeyboardReplay, .deleteKeyboardReplay:
            controlKeyboard(command, reply: reply)
        case .beginCalibration:
            guard listening, let meters = try? JSONDecoder().decode(Double.self, from: argument), meters.isFinite, meters > 0 else {
                reply(nil, false); return
            }
            cancelCalibration()
            calibrationReply = reply
            let generation = calibrationGeneration
            stats.beginMouseDistanceCalibration(knownMeters: meters) { [weak self] result in
                guard let self, self.calibrationGeneration == generation else { return }
                self.calibrationReply = nil
                let data: InputCalibrationResult
                switch result {
                case let .success(pixels, factor): data = .init(pixels: pixels, factor: factor)
                case let .failure(pixels): data = .init(pixels: pixels, factor: nil)
                }
                reply(try? JSONEncoder().encode(data), true)
            }
        case .calibrationPixels:
            let progress = InputCalibrationProgress(moving: stats.isMouseDistanceCalibrating,
                pixels: stats.currentMouseDistanceCalibrationPixels())
            reply(try? JSONEncoder().encode(progress), true)
        case .cancelCalibration:
            cancelCalibration()
            reply(nil, true)
        }
    }

    private func cancelCalibration() {
        calibrationGeneration &+= 1
        statsStorage?.cancelMouseDistanceCalibration()
        let reply = calibrationReply
        calibrationReply = nil
        reply?(nil, false)
    }

    private func controlKeyboard(_ command: InputControl, reply: @escaping (Data?, Bool) -> Void) {
        let send: (Bool) -> Void = { ok in reply(try? JSONEncoder().encode(self.keyboard.status.rawValue), ok) }
        switch command {
        case .enableKeyboardReplay:
            guard listening else { send(false); return }
            keyboard.enableInteractively(completion: send)
        case .disableKeyboardReplay: send(keyboard.setEnabled(false, interactive: true))
        case .flushKeyboardReplay: keyboard.flushForReading { send(true) }
        case .deleteKeyboardReplay: keyboard.deleteAll(completion: send)
        default: send(true)
        }
    }
}
