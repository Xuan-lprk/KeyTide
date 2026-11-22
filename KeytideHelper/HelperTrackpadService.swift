import Foundation

/// Main-queue owner of the physical device and encrypted writer. The preview
/// subscription belongs to the UI connection, while recording consent does not.
final class HelperTrackpadService {
    private let recorder: TrackpadRecording
    private var statusObserver: NSObjectProtocol?
    private var pendingPreview: [TrackpadFrame] = []
    private var previewDeliveryQueued = false
    var sendPreview: ((Data) -> Void)?
    var sendStatus: ((TrackpadRecordingStatus) -> Void)?

    init(recorder: TrackpadRecording = TrackpadRecording()) {
        self.recorder = recorder
        statusObserver = NotificationCenter.default.addObserver(forName: TrackpadRecording.didChange,
            object: recorder, queue: .main) { [weak self] _ in self?.statusDidChange() }
        recorder.onFrame = { [weak self] frame in self?.enqueuePreview(frame) }
    }

    deinit {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
    }

    var status: TrackpadRecordingStatus {
        if recorder.failed { return .failed }
        if !recorder.recording { return .off }
        return recorder.suspended ? .suspended : .recording
    }

    func restore() {
        recorder.startObserving(restoreRecording: false)
    }

    func updatePresence(connected: Bool, allowsDetached: Bool) {
        if connected || allowsDetached {
            if !recorder.recording, recorder.hasRecordingConsent, !recorder.failed {
                recorder.setRecording(true, restoring: true)
            }
        } else {
            detachPreview()
            recorder.suspendCapture()
        }
    }

    func detachPreview() {
        recorder.preview = false
        pendingPreview.removeAll(keepingCapacity: false)
        recorder.updateCapture()
    }

    func finish() { recorder.finish() }

    func control(_ command: TrackpadControl, reply: @escaping (Int, Bool) -> Void) {
        switch command {
        case .status:
            break
        case .enable:
            recorder.enableInteractively { ok in reply(self.status.rawValue, ok) }
            return
        case .disable:
            recorder.setRecording(false)
        case .startPreview:
            recorder.preview = true
            recorder.updateCapture()
        case .stopPreview:
            detachPreview()
        case .flush:
            recorder.flushForReading { reply(self.status.rawValue, true) }
            return
        case .delete:
            recorder.deleteAll { ok in reply(self.status.rawValue, ok) }
            return
        }
        reply(status.rawValue, status != .failed)
    }

    private func statusDidChange() {
        sendStatus?(status)
    }

    private func enqueuePreview(_ frame: TrackpadFrame) {
        // Capture already delivers batches on main. Only encode/send one frame
        // packet per delivery, and only while the UI is visibly subscribed.
        guard recorder.preview, sendPreview != nil else { return }
        pendingPreview.append(frame)
        guard !previewDeliveryQueued else { return }
        previewDeliveryQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.previewDeliveryQueued = false
            let frames = self.pendingPreview
            self.pendingPreview.removeAll(keepingCapacity: true)
            guard self.recorder.preview, !frames.isEmpty, let send = self.sendPreview,
                  let data = try? JSONEncoder().encode(frames) else { return }
            send(data)
        }
    }
}
