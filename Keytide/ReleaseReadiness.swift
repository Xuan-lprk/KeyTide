import Foundation

/// Main-thread presentation state, independent of XPC authorization state.
final class MonitoringStatus {
    static let shared = MonitoringStatus()
    static let didChange = Notification.Name("Keytide.monitoringStatusDidChange")
    enum State: Equatable {
        case idle, starting, monitoring
        case failed(code: Int)
        case installationFailed(String)
    }
    private(set) var state: State = .idle
    private var generation = 0

    @discardableResult func begin() -> Int {
        generation += 1
        set(.starting)
        return generation
    }
    @discardableResult func finish(token: Int, ok: Bool, code: Int) -> Bool {
        guard token == generation, state == .starting else { return false }
        set(ok || code == 3 ? .monitoring : .failed(code: code))
        return state == .monitoring
    }
    func invalidate() { generation += 1; set(.idle) }
    func connectionLost() { generation += 1; set(.failed(code: 2)) }
    func installationFailed(_ error: String) { generation += 1; set(.installationFailed(error)) }
    private func set(_ value: State) {
        state = value
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
    var failureDescription: String? {
        switch state {
        case .failed(let code):
            return NSLocalizedString(code == 1 ? "monitoring.permissionFailed" : "monitoring.tapFailed", comment: "")
        case .installationFailed(let error):
            return NSLocalizedString("monitoring.installFailed", comment: "") + "\n" + error
        default: return nil
        }
    }
}

/// Transaction boundary: injected service operations allow failure testing without launchd.
struct HelperServiceSwitch {
    struct RemovalTimedOut: Error {}

    struct Legacy {
        let url: URL
        let label: String
        let data: Data
        let wasLoaded: Bool
    }
    struct RecoveryFailure: Error, LocalizedError {
        let primary: Error
        let recovery: Error
        var errorDescription: String? { "\(primary.localizedDescription) — recovery: \(recovery.localizedDescription)" }
    }
    let fileManager: FileManager
    let unload: (String) throws -> Void
    let load: (URL) throws -> Void

    static func stopIfLoaded(isLoaded: () -> Bool, stop: () throws -> Void, pause: () -> Void) throws {
        guard isLoaded() else { return }
        do {
            try stop()
        } catch {
            // launchd may have already removed the service between print and bootout.
            if isLoaded() { throw error }
            return
        }
        // A successful bootout can return before the job finishes shutting down.
        for _ in 0..<50 {
            guard isLoaded() else { return }
            pause()
        }
        if isLoaded() { throw RemovalTimedOut() }
    }

    func perform(legacy: Legacy?, newURL: URL, newLabel: String,
                 previousNewData: Data? = nil, activate: () throws -> Void) throws {
        if let legacy, legacy.wasLoaded { try unload(legacy.label) }
        do {
            try activate()
            if let legacy { try fileManager.removeItem(at: legacy.url) }
        } catch {
            let primary = error
            // Never reload the old service unless the new one has been stopped.
            do {
                try unload(newLabel)
                if let previousNewData { try previousNewData.write(to: newURL, options: .atomic) }
                else if fileManager.fileExists(atPath: newURL.path) { try fileManager.removeItem(at: newURL) }
                if let legacy {
                    try legacy.data.write(to: legacy.url, options: .atomic)
                    if legacy.wasLoaded { try load(legacy.url) }
                }
            } catch {
                throw RecoveryFailure(primary: primary, recovery: error)
            }
            throw primary
        }
    }

    static func matchingLegacy(at url: URL, home: URL, isLoaded: (String) -> Bool) throws -> Legacy? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let label = "com.xuanlprk.KeyStatsMac.helper"
        let binary = home.appendingPathComponent("Library/Application Support/KeyStatsMac/Helper/KeyStatsHelper.app/Contents/MacOS/KeyStatsHelper").path
        guard plist["Label"] as? String == label,
              plist["ProgramArguments"] as? [String] == [binary],
              (plist["MachServices"] as? [String: Bool])?[label] == true else { return nil }
        return Legacy(url: url, label: label, data: data, wasLoaded: isLoaded(label))
    }
}

enum ActivityMonthLayout {
    static func height(for date: Date, calendar: Calendar = .current) -> CGFloat {
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: date)),
              let days = calendar.range(of: .day, in: .month, for: first) else { return 315 }
        let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let rows = (leading + days.count + 6) / 7
        return CGFloat(75 + (rows - 1) * 43 + 35 + 8)
    }
}
