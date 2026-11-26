import Cocoa
import Darwin
import CryptoKit
import LocalAuthentication
import Security

// Private ABI adapted from OpenMultitouchSupport (MIT).
// See scripts/trackpad-probe/THIRD_PARTY_NOTICES.md. Private input adapter; persistence is separately opt-in.
struct TrackpadContact: Codable {
    let identity: Int32
    let state: Int32
    let sourceTime: Double
    let position: CGPoint
    let rawPressure: Float?
}
struct TrackpadFrame: Codable {
    let sourceTime: Double
    let ordinal: Int32
    let contacts: [TrackpadContact]
}

#if KEYTIDE_HELPER
private typealias TrackpadCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Void
private enum TrackpadBridge {
    static let lock = NSLock()
    static var receive: ((TrackpadFrame, Double) -> Void)?
    // Keep the framework loaded until process exit: late private callbacks must
    // never return into unloaded code.
    static let library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL)
    static let callback: TrackpadCallback = { _, data, count, time, ordinal in
        let receivedAt = ProcessInfo.processInfo.systemUptime
        guard (0...32).contains(count), time.isFinite, time >= 0, count == 0 || data != nil else { return }
        var contacts: [TrackpadContact] = []
        for index in 0..<Int(count) {
            let p = data!.advanced(by: index * 96)
            let sourceTime = p.loadUnaligned(fromByteOffset: 8, as: Double.self)
            let identity = p.loadUnaligned(fromByteOffset: 16, as: Int32.self)
            let state = p.loadUnaligned(fromByteOffset: 20, as: Int32.self)
            let x = p.loadUnaligned(fromByteOffset: 32, as: Float.self)
            let y = p.loadUnaligned(fromByteOffset: 36, as: Float.self)
            let pressure = p.loadUnaligned(fromByteOffset: 52, as: Float.self)
            guard sourceTime.isFinite, sourceTime >= 0, (0...7).contains(state),
                  x.isFinite, y.isFinite, (-0.05...1.05).contains(x), (-0.05...1.05).contains(y) else { return }
            contacts.append(TrackpadContact(identity: identity, state: state, sourceTime: sourceTime,
                position: CGPoint(x: CGFloat(x), y: CGFloat(y)), rawPressure: pressure.isFinite ? pressure : nil))
        }
        lock.lock(); let handler = receive; lock.unlock()
        handler?(TrackpadFrame(sourceTime: time, ordinal: ordinal, contacts: contacts), receivedAt)
    }
}

/// Bounded callback delivery. Overflow emits an empty boundary before the next
/// frame. Raw surface positions never enter logs or aggregate statistics.
protocol TrackpadCapturing: AnyObject {
    var onFrame: ((TrackpadFrame, Double) -> Void)? { get set }
    func start() -> Bool
    func stop()
    func setInteractiveDelivery(_ enabled: Bool)
}

extension TrackpadCapturing {
    func setInteractiveDelivery(_ enabled: Bool) {}
}

final class TrackpadPreviewCapture: TrackpadCapturing {
    private typealias Create = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, TrackpadCallback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias Release = @convention(c) (UnsafeMutableRawPointer) -> Void
    private var device: UnsafeMutableRawPointer?
    private var unregister: Register?, stopDevice: Stop?, releaseDevice: Release?
    private let lock = NSLock()
    private var pending: [(frame: TrackpadFrame, receivedAt: Double)] = []
    private var scheduled = false
    private var generation = 0
    private var accepting = false
    private var deliveryInterval = 0.08
    var onFrame: ((TrackpadFrame, Double) -> Void)?
    deinit { stop() }

    private func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let library = TrackpadBridge.library, let address = dlsym(library, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }
    func start() -> Bool {
        if device != nil { return true }
        guard let create = symbol("MTDeviceCreateDefault", Create.self),
              let register = symbol("MTRegisterContactFrameCallback", Register.self),
              let unregister = symbol("MTUnregisterContactFrameCallback", Register.self),
              let start = symbol("MTDeviceStart", Start.self),
              let stop = symbol("MTDeviceStop", Stop.self),
              let release = symbol("MTDeviceRelease", Release.self) else { return false }
        TrackpadBridge.lock.lock()
        guard TrackpadBridge.receive == nil else { TrackpadBridge.lock.unlock(); return false }
        lock.lock(); generation &+= 1; let token = generation; lock.unlock()
        TrackpadBridge.receive = { [weak self] frame, receivedAt in self?.enqueue(frame, receivedAt: receivedAt, generation: token) }
        TrackpadBridge.lock.unlock()
        guard let device = create() else {
            TrackpadBridge.lock.lock(); TrackpadBridge.receive = nil; TrackpadBridge.lock.unlock()
            return false
        }
        self.device = device; self.unregister = unregister; stopDevice = stop; releaseDevice = release
        lock.lock(); accepting = true; lock.unlock()
        register(device, TrackpadBridge.callback)
        guard start(device, 0) == 0 else { self.stop(); return false }
        return true
    }
    func stop() {
        lock.lock(); accepting = false; generation &+= 1; pending.removeAll(); scheduled = false; lock.unlock()
        guard let device else { return }
        self.device = nil
        TrackpadBridge.lock.lock(); TrackpadBridge.receive = nil; TrackpadBridge.lock.unlock()
        unregister?(device, TrackpadBridge.callback); _ = stopDevice?(device); releaseDevice?(device)
    }

    func setInteractiveDelivery(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        deliveryInterval = enabled ? (1.0 / 60) : 0.08
    }

    private func enqueue(_ frame: TrackpadFrame, receivedAt: Double, generation token: Int) {
        lock.lock()
        guard accepting, token == generation else { lock.unlock(); return }
        // Preserve every callback between UI deliveries, rather than dropping
        // all intermediate positions. Overflow starts a new visible segment.
        if pending.count >= 256 { pending.removeAll(); pending.append((TrackpadFrame(sourceTime: frame.sourceTime, ordinal: frame.ordinal, contacts: []), receivedAt)) }
        pending.append((frame, receivedAt))
        guard !scheduled else { lock.unlock(); return }
        scheduled = true
        let delay = deliveryInterval
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.accepting, token == self.generation else { self.lock.unlock(); return }
            let values = self.pending; self.pending.removeAll(keepingCapacity: true); self.scheduled = false
            self.lock.unlock()
            for value in values { self.onFrame?(value.frame, value.receivedAt) }
        }
    }
}

/// Local-only opt-in recorder. Main-thread ingress, bounded queued encrypted
/// batches; the serial I/O queue also orders loads and deletion after writes.
final class TrackpadRecording {
    static let didChange = Notification.Name("Keytide.trackpadRecordingChanged")
    private let capture: TrackpadCapturing
    private let defaults: UserDefaults
    private let keyProvider: ((Bool) throws -> SymmetricKey)?
    private let uptime: () -> Double
    private let queue = DispatchQueue(label: "Keytide.TrackpadRecords", qos: .utility)
    private let gate = NSLock()
    private var outstanding = 0
    private var activeLoad: TrackpadReplayLoad?
    private var batch: [TrackpadFrame] = []
    private var flushTask: DispatchWorkItem?
    private var key: SymmetricKey?
    private var session = UUID().uuidString
    private var chunk = 0
    private var recordingOrder = 0
    private var recordingGeneration = 0
    private var enableRequest = 0
    private var acceptsAfter: Double?
    private var batchDay = ""
    private var workspaceSuspensions = Set<Notification.Name>()
    private var observers: [NSObjectProtocol] = []
    private let preference = "trackpad.recording.consent.v1"
    private let directory: URL
    private(set) var recording = false
    private(set) var failed = false
    var hasRecordingConsent: Bool { defaults.bool(forKey: preference) }
    var suspended: Bool { !workspaceSuspensions.isEmpty }
    var preview = false
    var onFrame: ((TrackpadFrame) -> Void)?
    private let formatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    init(capture: TrackpadCapturing = TrackpadPreviewCapture(), defaults: UserDefaults = .standard,
         directory: URL? = nil, keyProvider: ((Bool) throws -> SymmetricKey)? = nil,
         uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.capture = capture; self.defaults = defaults; self.keyProvider = keyProvider; self.uptime = uptime
        self.directory = directory ?? TrackpadReplayLibrary.directory
        capture.onFrame = { [weak self] frame, receivedAt in
            guard let self else { return }
            // Callback receipt time is memory-only. A preview frame queued before
            // consent must not become a recorded frame when main-thread delivery resumes.
            if self.recording, let acceptsAfter = self.acceptsAfter, receivedAt >= acceptsAfter {
                let day = self.formatter.string(from: Date())
                if day != self.batchDay { self.flush(); self.batchDay = day }
                guard self.recording else { return }
                self.batch.append(frame)
                if self.batch.count >= 128 { self.flush() }
                else if self.flushTask == nil {
                    let task = DispatchWorkItem { [weak self] in self?.flushTask = nil; self?.flush() }
                    self.flushTask = task; DispatchQueue.main.asyncAfter(deadline: .now()+1, execute: task)
                }
            }
            if self.preview { self.onFrame?(frame) }
        }
    }
    deinit { observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver); activeLoad?.cancel() }
    func startObserving(restoreRecording: Bool = true) {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.workspaceSuspensions.insert(name); self.flush(); self.capture.stop(); self.publish()
            })
        }
        for (name, suspension) in [(NSWorkspace.didWakeNotification, NSWorkspace.willSleepNotification),
                                   (NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.workspaceSuspensions.remove(suspension)
                if self.workspaceSuspensions.isEmpty && self.recording { self.setRecording(true, restoring: true) }
                else { self.updateCapture(); self.publish() }
            })
        }
        if restoreRecording && hasRecordingConsent { setRecording(true, restoring: true) }
    }
    func updateCapture() {
        capture.setInteractiveDelivery(preview)
        if workspaceSuspensions.isEmpty && (preview || recording) {
            if !capture.start() { fail() }
        } else { capture.stop() }
    }

    /// Pause at an ownership boundary while preserving the user's recording consent.
    func suspendCapture() {
        enableRequest &+= 1
        flush()
        recording = false
        acceptsAfter = nil
        updateCapture()
        publish()
    }
    func enableInteractively(completion: @escaping (Bool) -> Void) {
        if recording { completion(true); return }
        enableRequest &+= 1
        let token = enableRequest
        let keyProvider = self.keyProvider
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let key = try? (keyProvider?(true) ?? TrackpadReplayLibrary.localKey(create: true))
            DispatchQueue.main.async {
                guard let self, self.enableRequest == token else { completion(false); return }
                guard let key else { self.fail(); completion(false); return }
                self.applyRecordingKey(key)
                completion(self.recording)
            }
        }
    }

    func setRecording(_ enabled: Bool, restoring: Bool = false) {
        enableRequest &+= 1
        flush(); recording = false; acceptsAfter = nil
        if enabled {
            do {
                try applyRecordingKey(localKey(create: !restoring, allowInteraction: !restoring))
            } catch { fail(); return }
        } else {
            failed = false
            defaults.set(false, forKey: preference)
            updateCapture()
            publish()
        }
    }
    private func applyRecordingKey(_ key: SymmetricKey) {
        recordingGeneration &+= 1
        self.key = key
        session = UUID().uuidString; chunk = 0
        let previous = defaults.integer(forKey: "trackpad.recording.order.v1")
        let next = previous == Int.max ? Int.max : previous + 1
        // v2 used a small per-process counter. Keep new sessions after those already written by the App.
        recordingOrder = max(next, Int(Date().timeIntervalSince1970 * 1_000))
        defaults.set(recordingOrder, forKey: "trackpad.recording.order.v1")
        acceptsAfter = uptime(); recording = true; failed = false
        defaults.set(true, forKey: preference)
        updateCapture()
        if recording { publish() }
    }
    private func fail() {
        enableRequest &+= 1
        recording = false; acceptsAfter = nil; failed = true; batch.removeAll(); flushTask?.cancel(); flushTask = nil
        defaults.set(false, forKey: preference)
        if !preview || !workspaceSuspensions.isEmpty { capture.stop() }
        publish()
    }
    private func publish() { NotificationCenter.default.post(name: Self.didChange, object: self) }
    func finish() { activeLoad?.cancel(); flush(); capture.stop(); queue.sync {} }
    func flushForReading(completion: @escaping () -> Void) {
        flush()
        queue.async { DispatchQueue.main.async { completion() } }
    }
    private func flush() {
        flushTask?.cancel(); flushTask = nil
        guard !batch.isEmpty, let key else { return }
        gate.lock()
        guard outstanding < 8 else { gate.unlock(); fail(); return }
        outstanding += 1; gate.unlock()
        let frames = batch; let token = recordingGeneration; batch.removeAll(keepingCapacity: true)
        let day = batchDay, filename = String(format: "%020lld", Int64(recordingOrder)) + "-" + session + String(format: "-%08d", chunk) + ".ktp"
        chunk += 1
        queue.async {
            defer { self.gate.lock(); self.outstanding -= 1; self.gate.unlock() }
            do {
                try self.prepare(self.directory)
                let folder = self.directory.appendingPathComponent(day); try self.prepare(folder)
                let data = try JSONEncoder().encode(frames)
                let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(("Keytide.Trackpad.v1/"+day).utf8)).combined!
                let file = folder.appendingPathComponent(filename)
                try sealed.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch { DispatchQueue.main.async { if self.recordingGeneration == token { self.fail() } } }
        }
    }
    private func prepare(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path), try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var value = url; var flags = URLResourceValues(); flags.isExcludedFromBackup = true; try value.setResourceValues(flags)
    }
    @discardableResult
    func load(day: Date, completion: @escaping (TrackpadReplayReader?) -> Void) -> TrackpadReplayLoad {
        activeLoad?.cancel()
        flush()
        let request = TrackpadReplayLibrary.load(day: day, directory: directory, on: queue,
            key: { try self.localKey(create: false) }, completion: completion)
        activeLoad = request
        return request
    }
    func deleteAll(completion: @escaping (Bool) -> Void) {
        setRecording(false)
        // A write being deleted must not later overwrite the deletion result.
        recordingGeneration &+= 1
        activeLoad?.cancel(); activeLoad = nil
        queue.async {
            do {
                if FileManager.default.fileExists(atPath: self.directory.path) { try FileManager.default.removeItem(at: self.directory) }
                DispatchQueue.main.async { completion(true) }
            } catch { DispatchQueue.main.async { self.fail(); completion(false) } }
        }
    }
    private func localKey(create: Bool, allowInteraction: Bool = true) throws -> SymmetricKey {
        if let keyProvider { return try keyProvider(create) }
        return try TrackpadReplayLibrary.localKey(create: create, allowInteraction: allowInteraction)
    }
}
#endif

enum TrackpadReplayLibrary {
    static let directory = HelperLocations.applicationSupportDirectory.appendingPathComponent("TrackpadReplay", isDirectory: true)
    private static let readQueue = DispatchQueue(label: "Keytide.TrackpadReplayLibrary", qos: .userInitiated)

    static func load(day: Date, directory: URL = TrackpadReplayLibrary.directory,
                     on queue: DispatchQueue = TrackpadReplayLibrary.readQueue,
                     key: @escaping () throws -> SymmetricKey = { try localKey(create: false) },
                     completion: @escaping (TrackpadReplayReader?) -> Void) -> TrackpadReplayLoad {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let dayKey = formatter.string(from: day)
        let request = TrackpadReplayLoad()
        queue.async {
            do {
                let folder = directory.appendingPathComponent(dayKey)
                guard !request.isCancelled, FileManager.default.fileExists(atPath: folder.path),
                      try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "ktp" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                let reader = TrackpadReplayReader(files: files, key: try key(), day: dayKey)
                guard request.install(reader) else { DispatchQueue.main.async { completion(nil) }; return }
                reader.prepare { ok in completion(ok && !request.isCancelled ? reader : nil) }
            } catch { DispatchQueue.main.async { completion(nil) } }
        }
        return request
    }

    fileprivate static func localKey(create: Bool, allowInteraction: Bool = true) throws -> SymmetricKey {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: HelperLocations.mainBundleId + ".TrackpadReplay.v1", kSecAttrAccount as String: "encryption",
            kSecAttrSynchronizable as String: false, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?; let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecSuccess, let data = item as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard result == errSecItemNotFound, create else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        let key = SymmetricKey(size: .bits256); var add = query
        add.removeValue(forKey: kSecReturnData as String); add.removeValue(forKey: kSecMatchLimit as String)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return key
    }
}

/// Cancellation is available before file enumeration or the first decryption.
/// Installing the reader and cancelling share a lock so neither can miss the other.
final class TrackpadReplayLoad {
    private let lock = NSLock()
    private var cancelled = false
    private var reader: TrackpadReplayReader?
    fileprivate var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    fileprivate func install(_ reader: TrackpadReplayReader) -> Bool {
        lock.lock()
        guard !cancelled else { lock.unlock(); reader.cancel(); return false }
        self.reader = reader; lock.unlock(); return true
    }
    func cancel() {
        lock.lock(); cancelled = true; let reader = reader; self.reader = nil; lock.unlock()
        reader?.cancel()
    }
}

/// Two-pass bounded decryption. Only file names and one authenticated chunk are
/// retained; there is no whole-day frame array or plaintext replay cache.
final class TrackpadReplayReader {
    private let files: [URL]
    private let key: SymmetricKey
    private let aad: Data
    private let queue = DispatchQueue(label: "Keytide.TrackpadReplayReader", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false
    private var fileIndex = 0, frameIndex = 0
    private var frames: [TrackpadFrame] = []
    private var previousFile: String?
    private var previousTime: Double?
    private var elapsed = 0.0, scale = 1.0
    private var pending: (TrackpadFrame, Double)?
    init(files: [URL], key: SymmetricKey, day: String) {
        self.files = files; self.key = key; aad = Data(("Keytide.Trackpad.v1/" + day).utf8)
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func decode(_ file: URL) throws -> [TrackpadFrame] {
        let info = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 2_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: file)), using: key, authenticating: aad)
        let values = try JSONDecoder().decode([TrackpadFrame].self, from: bytes)
        guard !values.isEmpty, values.count <= 128,
              values.allSatisfy({ frame in
                  frame.sourceTime.isFinite && frame.sourceTime >= 0 && frame.contacts.count <= 32 &&
                  Set(frame.contacts.map(\.identity)).count == frame.contacts.count &&
                  frame.contacts.allSatisfy { c in c.sourceTime.isFinite && (0...7).contains(c.state) &&
                      c.position.x.isFinite && c.position.y.isFinite &&
                      (-0.05...1.05).contains(c.position.x) && (-0.05...1.05).contains(c.position.y) &&
                      (c.rawPressure?.isFinite ?? true) }
              }) else { throw CocoaError(.fileReadCorruptFile) }
        return values
    }
    private func next() throws -> TrackpadFrame? {
        if frameIndex < frames.count { defer { frameIndex += 1 }; return frames[frameIndex] }
        guard fileIndex < files.count else { return nil }
        let file = files[fileIndex]; fileIndex += 1
        frames = try decode(file); frameIndex = 0
        let name = file.lastPathComponent
        let identity = String(name.dropLast(13))
        let number = Int(name.dropLast(4).suffix(8))
        let previousNumber = previousFile.flatMap { Int($0.dropLast(4).suffix(8)) }
        let contiguous = previousFile.map { String($0.dropLast(13)) == identity } == true &&
            number != nil && previousNumber != nil && number! == previousNumber! + 1
        previousFile = name
        if !contiguous, let first = frames.first {
            previousTime = nil
            return TrackpadFrame(sourceTime: first.sourceTime, ordinal: first.ordinal, contacts: [])
        }
        return try next()
    }
    func prepare(completion: @escaping (Bool) -> Void) {
        queue.async {
            do {
                var total = 0.0, last: Double?
                while !self.isCancelled, let frame = try self.next() {
                    if let last { total += min(0.12, max(0, frame.sourceTime - last)) }
                    last = frame.sourceTime
                }
                self.scale = min(1, 9.5 / max(0.001, total))
                self.fileIndex = 0; self.frameIndex = 0; self.frames = []
                self.previousFile = nil; self.previousTime = nil
                DispatchQueue.main.async { completion(!self.isCancelled && !self.files.isEmpty) }
            } catch { DispatchQueue.main.async { completion(false) } }
        }
    }
    func take(through time: Double, completion: @escaping ([TrackpadFrame], Bool, Bool) -> Void) {
        queue.async {
            var output: [TrackpadFrame] = [], done = false
            do {
                while output.count < 128 && !self.isCancelled {
                    if self.pending == nil {
                        guard let frame = try self.next() else { done = true; break }
                        if let previous = self.previousTime { self.elapsed += min(0.12, max(0, frame.sourceTime - previous)) * self.scale }
                        self.previousTime = frame.sourceTime
                        self.pending = (frame, self.elapsed)
                    }
                    guard let pending = self.pending, pending.1 <= time else { break }
                    output.append(pending.0); self.pending = nil
                }
                DispatchQueue.main.async { completion(output, done || self.isCancelled, false) }
            } catch { DispatchQueue.main.async { completion([], true, true) } }
        }
    }
}
