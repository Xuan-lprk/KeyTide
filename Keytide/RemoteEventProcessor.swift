import Foundation

/// Presents data from the current Helper session. The App never ingests raw keyboard or mouse events.
final class RemoteEventProcessor: NSObject, KeytideEventSinkProtocol {
    static let shared = RemoteEventProcessor()

    private override init() { super.init() }

    func receiveTrackpadPreview(_ frames: Data) {
        guard frames.count <= 2_000_000,
              let decoded = try? JSONDecoder().decode([TrackpadFrame].self, from: frames), decoded.count <= 257 else { return }
        deliver { TrackpadAppService.shared.receivePreview(decoded) }
    }

    func receiveTrackpadStatus(_ status: Int) {
        guard let status = TrackpadRecordingStatus(rawValue: status) else { return }
        deliver { TrackpadAppService.shared.receiveStatus(status) }
    }

    func receiveEvent(_ payload: [String: Any]) {
        // Version 4 sends aggregate snapshots. Ignore v2/v3 input while their
        // bundled Helper is being replaced to maintain a single writer.
    }

    func receiveInputSnapshot(_ data: Data) {
        guard let update = try? JSONDecoder().decode(StatsManager.CaptureUpdate.self, from: data) else { return }
        let historyPayload = update.containsHistory ? data : nil
        deliver { StatsManager.shared.receiveCaptureUpdate(update, historyPayload: historyPayload) }
    }

    func receiveKeyboardReplayStatus(_ status: Int) {
        deliver { KeyReplayRecording.shared.receiveStatus(status) }
    }

    func receiveThresholdNotification(_ isKeyPress: Bool, count: Int, threshold: Int) {
        deliver {
            guard StatsManager.shared.notificationsEnabled else { return }
            NotificationManager.shared.sendThresholdNotification(metric: isKeyPress ? .keyPresses : .clicks,
                                                                   count: count, threshold: threshold)
        }
    }

    private func deliver(_ update: @escaping () -> Void) {
        guard let connection = NSXPCConnection.current() else { return }
        DispatchQueue.main.async {
            guard HelperXPCClient.shared.isCurrent(connection) else { return }
            update()
        }
    }
}
