import Foundation
import CryptoKit
import Security
import LocalAuthentication

enum KeyReplayVault {
    static let directory = HelperLocations.applicationSupportDirectory.appendingPathComponent("LocalReplay", isDirectory: true)
    static let consentKey = "keyReplay.explicitConsent.v1"

    static func key(create: Bool, interactive: Bool = true) throws -> SymmetricKey {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: HelperLocations.mainBundleId + ".LocalReplay.v1",
            kSecAttrAccount as String: "encryption", kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if !interactive {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecSuccess, let data = item as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard result == errSecItemNotFound, create else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
        let key = SymmetricKey(size: .bits256)
        query.removeValue(forKey: kSecReturnData as String)
        query.removeValue(forKey: kSecMatchLimit as String)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        let added = SecItemAdd(query as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        return key
    }
}

#if KEYTIDE_HELPER
/// Ingress is serialized with the event tap. Disk work has a fixed eight-batch
/// limit. Without consent there is no key-up capture, buffer, or timer.
final class HelperKeyReplayWriter {
    private let defaults: UserDefaults
    private let directory: URL
    private let keyProvider: (Bool, Bool) throws -> SymmetricKey
    private let queue = DispatchQueue(label: "Keytide.KeyboardReplayWriter", qos: .utility)
    private let writesLock = NSLock()
    private var outstandingWrites = 0
    private var store: KeyReplayStore?
    private var session: KeyReplaySession?
    private var day = ""
    private var order: UInt64 = 0
    private var buffer: [KeyReplayEvent] = []
    private var flushTask: DispatchWorkItem?
    private var generation = 0
    private var firstPermittedTimestamp: UInt64 = 0
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private(set) var status: TrackpadRecordingStatus = .off {
        didSet { if status != oldValue { statusChanged?(status) } }
    }
    var statusChanged: ((TrackpadRecordingStatus) -> Void)?
    var consent: Bool { defaults.bool(forKey: KeyReplayVault.consentKey) }

    init(defaults: UserDefaults, directory: URL = KeyReplayVault.directory,
         keyProvider: @escaping (Bool, Bool) throws -> SymmetricKey = { try KeyReplayVault.key(create: $0, interactive: $1) }) {
        self.defaults = defaults; self.directory = directory; self.keyProvider = keyProvider
    }

    func enableInteractively(completion: @escaping (Bool) -> Void) {
        if status == .recording { completion(true); return }
        suspend()
        let token = generation
        let keyProvider = self.keyProvider
        let directory = self.directory
        // An existing key can trigger a system prompt on upgrade. Keep the
        // input run loop draining while the user responds.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let openedStore = try? KeyReplayStore(directory: directory, key: keyProvider(true, true))
            DispatchQueue.main.async {
                guard let self, self.generation == token else { completion(false); return }
                guard let openedStore else { self.status = .failed; completion(false); return }
                self.defaults.set(true, forKey: KeyReplayVault.consentKey)
                self.beginRecording(with: openedStore)
                completion(true)
            }
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, interactive: Bool) -> Bool {
        if interactive { defaults.set(enabled, forKey: KeyReplayVault.consentKey) }
        suspend()
        guard enabled, consent else { status = .off; return !enabled }
        do {
            let key = try keyProvider(interactive, interactive)
            try beginRecording(with: KeyReplayStore(directory: directory, key: key))
            return true
        } catch {
            status = .failed
            return false
        }
    }

    private func beginRecording(with store: KeyReplayStore) {
        self.store = store
        firstPermittedTimestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        status = .recording
    }

    func suspend() {
        flush()
        generation &+= 1
        store = nil; session = nil
        status = consent ? .suspended : .off
    }

    func receive(time: UInt64, keyCode: UInt16, phase: KeyReplayEvent.Phase, growthKeys: [String]) {
        guard status == .recording, time >= firstPermittedTimestamp else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        let date = Date().addingTimeInterval(-max(0, uptime - Double(time) / 1_000_000_000))
        dayFormatter.timeZone = .current
        let dateKey = dayFormatter.string(from: date)
        if session == nil || dateKey != day {
            flush()
            guard status == .recording else { return }
            day = dateKey
            session = KeyReplaySession(startedAt: date, originNanoseconds: time)
            let previous = UInt64(max(0, defaults.integer(forKey: "keyReplay.sessionOrder.v1")))
            order = max(previous + 1, UInt64(max(0, Date().timeIntervalSince1970 * 1_000)))
            defaults.set(Int(clamping: order), forKey: "keyReplay.sessionOrder.v1")
        }
        guard let event = session?.event(nanoseconds: time, keyCode: keyCode, phase: phase, growthKeys: growthKeys) else { return }
        buffer.append(event)
        if buffer.count >= 128 { flush() }
        else if flushTask == nil {
            let task = DispatchWorkItem { [weak self] in self?.flush() }
            flushTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: task)
        }
    }

    func captureGap() { if session != nil { flush(); session = nil } }

    private func flush() {
        flushTask?.cancel(); flushTask = nil
        guard let store, let session, !buffer.isEmpty else { return }
        writesLock.lock()
        guard outstandingWrites < 8 else {
            writesLock.unlock()
            fail()
            return
        }
        outstandingWrites += 1
        writesLock.unlock()
        let batch = KeyReplayBatch(version: 1, session: session.id, startedAt: session.startedAt,
                                   events: buffer, recordingOrder: order)
        buffer.removeAll(keepingCapacity: true)
        let dateKey = day, token = generation
        queue.async {
            defer { self.writesLock.lock(); self.outstandingWrites -= 1; self.writesLock.unlock() }
            do { try store.append(batch, day: dateKey) }
            catch { DispatchQueue.main.async { if token == self.generation { self.fail() } } }
        }
    }

    private func fail() {
        store = nil; buffer.removeAll(); session = nil
        status = .failed
    }

    func flushForReading(completion: @escaping () -> Void) {
        flush()
        queue.async { DispatchQueue.main.async { completion() } }
    }

    func deleteAll(completion: @escaping (Bool) -> Void) {
        setEnabled(false, interactive: true)
        queue.async {
            let ok: Bool
            do {
                let deletionStore = try KeyReplayStore(directory: self.directory, key: SymmetricKey(size: .bits256))
                try deletionStore.deleteAll()
                ok = true
            } catch { ok = false }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func finish() { flush(); queue.sync {} }
}
#endif
