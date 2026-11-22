import AppKit

extension Notification.Name {
    static let keyReplayRecordingChanged = Notification.Name("Keytide.keyReplayRecordingChanged")
    static let keyReplayRecordsDeleted = Notification.Name("Keytide.keyReplayRecordsDeleted")
}

/// Replay preferences and a read-only client. The Helper owns capture, encryption,
/// batching and deletion. The UI decodes the authenticated file for presentation.
final class KeyReplayRecording {
    static let shared = KeyReplayRecording()
    private let helper = HelperXPCClient.shared
    private let readerQueue = DispatchQueue(label: "Keytide.KeyboardReplayPresentation", qos: .userInitiated)
    private var activeRead: KeyReplayCancellation?
    private var status: TrackpadRecordingStatus = .off
    private(set) var changing = false
    var statusKey: String {
        if changing { return "replay.recording.starting" }
        switch status {
        case .off: return "replay.recording.off"
        case .recording: return "replay.recording.on"
        case .failed: return "replay.recording.unavailable"
        case .suspended: return "replay.recording.suspended"
        }
    }
    var isEnabled: Bool { status == .recording || status == .suspended }

    func startObserving() {
        helper.addStateObserver { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.helper.state == state else { return }
                if case .connected = state { self.send(.keyboardReplayStatus) { _ in } }
                else { self.receiveStatus(TrackpadRecordingStatus.off.rawValue) }
            }
        }
    }

    func receiveStatus(_ value: Int) {
        guard let status = TrackpadRecordingStatus(rawValue: value) else { return }
        self.status = status
        publish()
    }

    func setEnabled(_ enabled: Bool, completion: ((Bool) -> Void)? = nil) {
        guard !changing else { completion?(false); return }
        changing = true
        publish()
        send(enabled ? .enableKeyboardReplay : .disableKeyboardReplay) { [weak self] ok in
            self?.changing = false
            self?.publish()
            completion?(ok)
        }
    }

    private func publish() { NotificationCenter.default.post(name: .keyReplayRecordingChanged, object: nil) }

    private func send(_ command: InputControl, completion: @escaping (Bool) -> Void) {
        helper.controlInput(command) { [weak self] data, ok in
            DispatchQueue.main.async {
                if let data, let raw = try? JSONDecoder().decode(Int.self, from: data) { self?.receiveStatus(raw) }
                else if !ok, command != .flushKeyboardReplay { self?.receiveStatus(TrackpadRecordingStatus.failed.rawValue) }
                completion(ok)
            }
        }
    }

    @discardableResult
    func load(day: String, completion: @escaping (Result<GrowthReplayPressPlan, Error>) -> Void) -> (() -> Void) {
        activeRead?.cancel()
        let request = KeyReplayCancellation()
        activeRead = request
        send(.flushKeyboardReplay) { [weak self] _ in
            guard let self, !request.isCancelled else { return }
            self.readerQueue.async {
                do {
                    guard !request.isCancelled else { return }
                    if !FileManager.default.fileExists(atPath: KeyReplayVault.directory.path) {
                        DispatchQueue.main.async { if !request.isCancelled { completion(.success(GrowthReplayPressPlan(day: .empty))) } }
                        return
                    }
                    let store = try KeyReplayStore(directory: KeyReplayVault.directory, key: KeyReplayVault.key(create: false))
                    let reader = try store.makeReader(day: day, cancellation: request)
                    reader.prepare(completion: completion)
                } catch {
                    DispatchQueue.main.async { if !request.isCancelled { completion(.failure(error)) } }
                }
            }
        }
        return { request.cancel() }
    }

    func deleteAll(completion: @escaping (Bool) -> Void) {
        activeRead?.cancel(); activeRead = nil
        send(.deleteKeyboardReplay) { ok in
            if ok { NotificationCenter.default.post(name: .keyReplayRecordsDeleted, object: nil) }
            completion(ok)
        }
    }

    func shutdown() { activeRead?.cancel(); activeRead = nil }
}
