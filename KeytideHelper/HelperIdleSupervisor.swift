import Foundation

final class HelperIdleSupervisor {
    private let idleTimeout: TimeInterval
    private let onIdleExit: () -> Void
    private var timer: DispatchSourceTimer?
    private var hasActiveConnection = false
    private var hasBackgroundWork = false
    private let queue = DispatchQueue(label: "com.xuanlprk.KeyTide.helper.idle")

    init(idleTimeout: TimeInterval = 30, onIdleExit: @escaping () -> Void = {
        NSLog("[KeytideHelper] idle timeout, exiting")
        exit(0)
    }) {
        self.idleTimeout = idleTimeout
        self.onIdleExit = onIdleExit
        scheduleIdleExit()
    }

    func connectionDidOpen() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.hasActiveConnection = true
            self.cancelIdleExit()
        }
    }

    func noteActivity() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.updateIdleDeadline()
        }
    }

    func connectionDidClose() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.hasActiveConnection = false
            self.updateIdleDeadline()
        }
    }

    /// The recorder keeps the launch agent alive while it owns recording work.
    /// Connection state alone no longer determines whether the process is idle.
    func setBackgroundWorkActive(_ active: Bool) {
        queue.async { [weak self] in
            guard let self, self.hasBackgroundWork != active else { return }
            self.hasBackgroundWork = active
            self.updateIdleDeadline()
        }
    }

    private func updateIdleDeadline() {
        if hasActiveConnection || hasBackgroundWork { cancelIdleExit() }
        else { scheduleIdleExit() }
    }

    private func scheduleIdleExit() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + idleTimeout)
        t.setEventHandler { [weak self] in
            guard let self, !self.hasActiveConnection, !self.hasBackgroundWork else { return }
            self.cancelIdleExit()
            self.onIdleExit()
        }
        t.resume()
        timer = t
    }

    private func cancelIdleExit() {
        timer?.cancel()
        timer = nil
    }
}
