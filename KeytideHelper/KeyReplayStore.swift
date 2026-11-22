import Foundation
import CryptoKit

/// A separate, opt-in data format. Never part of DailyStats or statistics exports.
struct KeyReplayEvent: Codable, Equatable {
    enum Phase: String, Codable { case down, up, pulse }
    let milliseconds: UInt64
    let ordinal: UInt64
    let keyCode: UInt16
    let phase: Phase
    // Physical participation IDs only, using the existing statistics mapping.
    let growthKeys: [String]
}

struct KeyReplayBatch: Codable {
    let version: Int
    let session: UUID
    let startedAt: Date
    let events: [KeyReplayEvent]
    var recordingOrder: UInt64? = nil
}

struct KeyReplayDay {
    struct Entry {
        let seconds: Double
        let event: KeyReplayEvent
        let startsSession: Bool
    }
    let entries: [Entry]
    let hasUnreadableChunks: Bool
    static let empty = KeyReplayDay(entries: [], hasUnreadableChunks: false)

    init(batches: [KeyReplayBatch], hasUnreadableChunks: Bool = false) {
        let sessions = Dictionary(grouping: batches, by: \.session).values.sorted {
            let a = $0[0], b = $1[0]
            if a.recordingOrder != b.recordingOrder { return (a.recordingOrder ?? 0) < (b.recordingOrder ?? 0) }
            if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
            return a.session.uuidString < b.session.uuidString
        }
        let origin = sessions.first?.first?.startedAt ?? .distantPast
        var result: [Entry] = []
        for batches in sessions {
            // A manual clock change must not reverse captured session order.
            let start = max(result.last?.seconds ?? 0, batches[0].startedAt.timeIntervalSince(origin))
            let events = batches.flatMap(\.events).sorted { $0.ordinal < $1.ordinal }
            for (index, event) in events.enumerated() {
                result.append(Entry(seconds: max(0, start + Double(event.milliseconds) / 1_000),
                    event: event, startsSession: index == 0))
            }
        }
        // Start at the first captured key; preserve all subsequent recorded gaps.
        let first = result.first?.seconds ?? 0
        entries = result.map { Entry(seconds: max(0, $0.seconds - first), event: $0.event, startsSession: $0.startsSession) }
        self.hasUnreadableChunks = hasUnreadableChunks
    }

    init(entries: [Entry], hasUnreadableChunks: Bool) {
        self.entries = entries; self.hasUnreadableChunks = hasUnreadableChunks
    }
}

/// Call on the recorder's serial queue. One file per capture session, containing
/// independently authenticated bounded chunks. A truncated tail never discards
/// earlier valid chunks. No plaintext journal or per-keystroke disk write.
final class KeyReplayStore {
    enum Failure: Error { case invalidDay, invalidBatch, oversizedChunk, unsafePath }
    let directory: URL
    private let key: SymmetricKey
    private let files: FileManager
    private let maxChunkSize = 1_048_576

    init(directory: URL, key: SymmetricKey, files: FileManager = .default) throws {
        self.directory = directory; self.key = key; self.files = files
        try makePrivateDirectory(directory)
    }

    func append(_ batch: KeyReplayBatch, day: String) throws {
        guard Self.valid(day) else { throw Failure.invalidDay }
        guard batch.version == 1, !batch.events.isEmpty, batch.events.count <= 128 else { throw Failure.invalidBatch }
        let folder = directory.appendingPathComponent(day, isDirectory: true)
        try makePrivateDirectory(folder)
        let plaintext = try JSONEncoder().encode(batch)
        let aad = Data(("Keytide.KeyReplay.v1/" + day).utf8)
        let encrypted = try AES.GCM.seal(plaintext, using: key, authenticating: aad).combined!
        guard encrypted.count <= maxChunkSize else { throw Failure.oversizedChunk }
        let url = folder.appendingPathComponent(batch.session.uuidString + ".ktr")
        var length = UInt32(encrypted.count).littleEndian
        var chunk = withUnsafeBytes(of: &length) { Data($0) }
        chunk.append(encrypted)
        if files.fileExists(atPath: url.path) {
            try rejectSymlink(url)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: chunk)
        } else {
            try chunk.write(to: url, options: [.atomic])
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func load(day: String) throws -> KeyReplayDay {
        guard Self.valid(day) else { throw Failure.invalidDay }
        let folder = directory.appendingPathComponent(day, isDirectory: true)
        guard files.fileExists(atPath: folder.path) else { return .empty }
        try rejectSymlink(folder)
        var batches: [KeyReplayBatch] = [], damaged = false
        for url in try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) where url.pathExtension == "ktr" {
            do {
                try rejectSymlink(url)
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let prefix = try handle.read(upToCount: 4), !prefix.isEmpty {
                    guard prefix.count == 4 else { throw Failure.invalidBatch }
                    let length = prefix.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
                    guard length > 0, length <= maxChunkSize,
                          let bytes = try handle.read(upToCount: Int(length)), bytes.count == Int(length) else { throw Failure.invalidBatch }
                    let box = try AES.GCM.SealedBox(combined: bytes)
                    let plaintext = try AES.GCM.open(box, using: key, authenticating: Data(("Keytide.KeyReplay.v1/" + day).utf8))
                    let batch = try JSONDecoder().decode(KeyReplayBatch.self, from: plaintext)
                    guard batch.version == 1, batch.events.count <= 128,
                          batch.events.allSatisfy({ $0.keyCode <= 255 && $0.growthKeys.count <= 8 }) else { throw Failure.invalidBatch }
                    batches.append(batch)
                }
            } catch { damaged = true }
        }
        return KeyReplayDay(batches: batches, hasUnreadableChunks: damaged)
    }

    func deleteAll() throws {
        try rejectSymlink(directory)
        for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            // Only this feature's ISO date folders; never touch statistics/Helper.
            if Self.valid(url.lastPathComponent) { try files.removeItem(at: url) }
        }
    }

#if !KEYTIDE_HELPER
    /// Snapshot file lengths on the writer queue; decryption runs on the reader queue.
    func makeReader(day: String, cancellation: KeyReplayCancellation = KeyReplayCancellation()) throws -> KeyReplayStream {
        guard Self.valid(day) else { throw Failure.invalidDay }
        let folder = directory.appendingPathComponent(day, isDirectory: true)
        var snapshots: [(URL, UInt64)] = []
        if files.fileExists(atPath: folder.path) {
            try rejectSymlink(folder)
            for url in try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) where url.pathExtension == "ktr" {
                try rejectSymlink(url)
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                snapshots.append((url, UInt64(max(0, size))))
            }
        }
        return KeyReplayStream(files: snapshots, key: key, day: day, cancellation: cancellation)
    }

#endif

    private static func valid(_ day: String) -> Bool {
        day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
    private func rejectSymlink(_ url: URL) throws {
        if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw Failure.unsafePath }
    }
    private func makePrivateDirectory(_ url: URL) throws {
        try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try rejectSymlink(url)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        var resourceURL = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }
}

#if !KEYTIDE_HELPER
/// Cancellation is synchronous; all reader state and I/O stays on its own serial queue.
final class KeyReplayCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Retains chunk metadata and bounded event buffers, never a whole day's plaintext.
/// Existing authenticated v1 session files remain unchanged.
final class KeyReplayStream {
    struct Slice {
        let entries: [KeyReplayDay.Entry]
        let nextSeconds: Double?
        let nextStartsSession: Bool
        let failed: Bool
        var done: Bool { nextSeconds == nil }
    }
    private struct Chunk {
        let url: URL
        let offset: UInt64
        let length: Int
        let session: UUID
        let startedAt: Date
        let order: UInt64?
        let first: UInt64
        let last: UInt64
        let count: Int
    }
    private let files: [(URL, UInt64)]
    private let key: SymmetricKey
    private let aad: Data
    private let queue = DispatchQueue(label: "Keytide.KeyReplayReader", qos: .userInitiated)
    let cancellation: KeyReplayCancellation
    private var chunks: [Chunk] = []
    private var chunkIndex = 0
    private var buffer: [KeyReplayEvent] = []
    private var bufferIndex = 0
    private var bufferChunk: Chunk?
    private var session: UUID?
    private var sessionStart = 0.0
    private var origin: Date?
    private var firstTime: Double?
    private var previousTime = 0.0
    private var compressedTime = 0.0
    private var previousRaw: Double?
    private var pending: KeyReplayDay.Entry?
    private var scale = 1.0
    private(set) var eventCount = 0
    private(set) var hasUnreadableChunks = false
    private(set) var isAccelerated = false
    private(set) var duration = 0.0

    init(files: [(URL, UInt64)], key: SymmetricKey, day: String, cancellation: KeyReplayCancellation = KeyReplayCancellation()) {
        self.cancellation = cancellation
        self.files = files; self.key = key
        aad = Data(("Keytide.KeyReplay.v1/" + day).utf8)
    }
    func cancel() {
        cancellation.cancel()
        queue.async { [weak self] in self?.chunks = []; self?.buffer = []; self?.pending = nil }
    }
    private func checkCancellation() throws {
        if cancellation.isCancelled { throw CancellationError() }
    }
    private func decode(_ url: URL, offset: UInt64, length: Int) throws -> KeyReplayBatch {
        try checkCancellation()
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw KeyReplayStore.Failure.unsafePath }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let bytes = try handle.read(upToCount: length), bytes.count == length else { throw KeyReplayStore.Failure.invalidBatch }
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: aad)
        let batch = try JSONDecoder().decode(KeyReplayBatch.self, from: data)
        guard batch.version == 1, !batch.events.isEmpty, batch.events.count <= 128,
              batch.startedAt.timeIntervalSince1970.isFinite,
              batch.events.allSatisfy({ $0.keyCode <= 255 && $0.growthKeys.count <= 8 }) else { throw KeyReplayStore.Failure.invalidBatch }
        return batch
    }
    func prepare(completion: @escaping (Result<GrowthReplayPressPlan, Error>) -> Void) {
        queue.async {
            do {
                try self.indexChunks()
                self.resetCursor()
                var last = 0.0
                while let entry = try self.nextRaw() {
                    self.compressedTime += min(GrowthReplayPressPlan.maximumGapSeconds, max(0, entry.seconds - last))
                    last = entry.seconds
                }
                self.scale = self.compressedTime > 0 ? min(1, GrowthReplayPressPlan.maximumDaySeconds / self.compressedTime) : 1
                self.duration = self.compressedTime * self.scale
                self.isAccelerated = self.duration + 0.000_001 < last
                self.resetCursor()
                try self.checkCancellation()
                DispatchQueue.main.async {
                    guard !self.cancellation.isCancelled else { return }
                    completion(.success(GrowthReplayPressPlan(stream: self)))
                }
            } catch {
                self.chunks = []; self.buffer = []
                DispatchQueue.main.async {
                    guard !self.cancellation.isCancelled else { return }
                    completion(.failure(error))
                }
            }
        }
    }
    private func indexChunks() throws {
        for (url, size) in files {
            try checkCancellation()
            do {
                guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw KeyReplayStore.Failure.unsafePath }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var offset: UInt64 = 0
                var fileSession: UUID?
                while offset < size {
                    try checkCancellation()
                    try handle.seek(toOffset: offset)
                    guard size - offset >= 4, let prefix = try handle.read(upToCount: 4), prefix.count == 4 else { throw KeyReplayStore.Failure.invalidBatch }
                    let length = prefix.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
                    guard length > 0, length <= 1_048_576, UInt64(length) <= size - offset - 4 else { throw KeyReplayStore.Failure.invalidBatch }
                    let batch = try autoreleasepool { try decode(url, offset: offset + 4, length: Int(length)) }
                    guard fileSession == nil || fileSession == batch.session else { throw KeyReplayStore.Failure.invalidBatch }
                    fileSession = batch.session
                    let sorted = batch.events.sorted { $0.ordinal < $1.ordinal }
                    chunks.append(Chunk(url: url, offset: offset + 4, length: Int(length), session: batch.session,
                        startedAt: batch.startedAt, order: batch.recordingOrder, first: sorted.first!.ordinal,
                        last: sorted.last!.ordinal, count: sorted.count))
                    offset += 4 + UInt64(length)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { hasUnreadableChunks = true }
        }
        chunks.sort {
            if $0.order != $1.order { return ($0.order ?? 0) < ($1.order ?? 0) }
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            if $0.session != $1.session { return $0.session.uuidString < $1.session.uuidString }
            return $0.first < $1.first
        }
        // The writer's ordinals are strictly increasing across bounded chunks.
        // Reject overlapping/malformed chunks rather than invent an input sequence.
        var previous: Chunk?
        chunks = chunks.filter { chunk in
            if let p = previous, p.session == chunk.session, chunk.first <= p.last {
                hasUnreadableChunks = true; return false
            }
            previous = chunk; return true
        }
        eventCount = chunks.reduce(0) { $0 + $1.count }
    }
    private func resetCursor() {
        chunkIndex = 0; buffer = []; bufferIndex = 0; bufferChunk = nil
        session = nil; origin = nil; firstTime = nil; sessionStart = 0; previousTime = 0
        compressedTime = 0; previousRaw = nil; pending = nil
    }
    private func nextRaw() throws -> KeyReplayDay.Entry? {
        try checkCancellation()
        if bufferIndex >= buffer.count {
            guard chunkIndex < chunks.count else { buffer = []; return nil }
            let chunk = chunks[chunkIndex]; chunkIndex += 1
            buffer = try autoreleasepool { try decode(chunk.url, offset: chunk.offset, length: chunk.length).events.sorted { $0.ordinal < $1.ordinal } }
            bufferIndex = 0; bufferChunk = chunk
        }
        let chunk = bufferChunk!, event = buffer[bufferIndex]; bufferIndex += 1
        let startsSession = session != chunk.session
        if startsSession {
            if origin == nil { origin = chunk.startedAt }
            sessionStart = max(previousTime, chunk.startedAt.timeIntervalSince(origin!))
            session = chunk.session
        }
        let time = max(0, sessionStart + Double(event.milliseconds) / 1000)
        if firstTime == nil { firstTime = time }
        previousTime = time
        return .init(seconds: max(0, time - firstTime!), event: event, startsSession: startsSession)
    }
    /// At most 1024 due events plus one lookahead are delivered per call.
    func take(through time: Double, completion: @escaping (Slice) -> Void) {
        queue.async {
            do {
                var output: [KeyReplayDay.Entry] = []
                while output.count < 1024 {
                    try self.checkCancellation()
                    if self.pending == nil {
                        guard let raw = try self.nextRaw() else { break }
                        self.compressedTime += min(GrowthReplayPressPlan.maximumGapSeconds, max(0, raw.seconds - (self.previousRaw ?? raw.seconds)))
                        self.previousRaw = raw.seconds
                        self.pending = .init(seconds: self.compressedTime * self.scale, event: raw.event, startsSession: raw.startsSession)
                    }
                    guard let next = self.pending, next.seconds <= time else { break }
                    output.append(next); self.pending = nil
                }
                // A full slice may have more due work. Do not finish or release held keys at this boundary.
                let nextTime = self.pending?.seconds ?? (output.count == 1024 ? time : nil)
                let slice = Slice(entries: output, nextSeconds: nextTime, nextStartsSession: self.pending?.startsSession ?? false, failed: false)
                DispatchQueue.main.async { if !self.cancellation.isCancelled { completion(slice) } }
            } catch {
                self.buffer = []; self.chunks = []; self.pending = nil
                DispatchQueue.main.async {
                    if !self.cancellation.isCancelled { completion(Slice(entries: [], nextSeconds: nil, nextStartsSession: false, failed: true)) }
                }
            }
        }
    }
}

#endif

/// Pure ingress policy and timestamp conversion. No text, app identity, network,
/// defaults or global listener. A new session is needed after a capture gap.
struct KeyReplaySession {
    let id = UUID()
    let startedAt: Date
    let originNanoseconds: UInt64
    private(set) var ordinal: UInt64 = 0
    private var lastNanoseconds: UInt64 = 0
    init(startedAt: Date, originNanoseconds: UInt64) {
        self.startedAt = startedAt
        self.originNanoseconds = originNanoseconds
    }
    mutating func event(nanoseconds: UInt64, keyCode: UInt16, phase: KeyReplayEvent.Phase,
                        growthKeys: [String]) -> KeyReplayEvent? {
        guard keyCode <= 255, nanoseconds >= originNanoseconds,
              nanoseconds >= lastNanoseconds else { return nil }
        lastNanoseconds = nanoseconds
        defer { ordinal += 1 }
        return KeyReplayEvent(milliseconds: (nanoseconds - originNanoseconds) / 1_000_000,
            ordinal: ordinal, keyCode: keyCode, phase: phase, growthKeys: growthKeys)
    }
}

/// Built-in, explicitly synthetic replay. No manager, defaults, file or recorder
/// dependency. It uses the same event and presentation types as real playback.
#if !KEYTIDE_HELPER
struct KeyReplayExample {
    let presentation: GrowthKeyboardPresentation
    let recordedDayKey: String
    let day: KeyReplayDay

    static func make(now: Date = Date(), calendar: Calendar = .current) -> KeyReplayExample {
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -1, to: today)!
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let firstKey = formatter.string(from: first), lastKey = formatter.string(from: today)
        // A seed makes the approved stable-growth model readable immediately;
        // each sample key-down still contributes exactly one participation.
        var seed = DailyStats(date: first)
        seed.keyPressCounts = ["A": 600, "J": 1200, "S": 1800, "I": 900, "H": 400,
            "Space": 2400, "K": 300, "E": 1500, "Y": 200, "T": 1000, "D": 500, "F": 700]
        seed.keyPresses = seed.keyPressCounts.values.reduce(0, +)
        var sample = DailyStats(date: today)
        // A J S I S H, Space, K E Y T I D E, Space, A S D F F D S A.
        let codes: [UInt16] = [0, 38, 1, 34, 1, 4, 49, 40, 14, 16, 17, 34, 2, 14, 49, 0, 1, 2, 3, 3, 2, 1, 0]
        var entries: [KeyReplayDay.Entry] = []
        var time: UInt64 = 0
        for (index, code) in codes.enumerated() {
            let id = MechanicalKeyboardView.physicalKeyID(code)!
            sample.keyPressCounts[id, default: 0] += 1; sample.keyPresses += 1
            entries.append(.init(seconds: Double(time) / 1000,
                event: .init(milliseconds: time, ordinal: UInt64(index * 2), keyCode: code,
                    phase: .down, growthKeys: [id]), startsSession: index == 0))
            let release = time + 130
            entries.append(.init(seconds: Double(release) / 1000,
                event: .init(milliseconds: release, ordinal: UInt64(index * 2 + 1), keyCode: code,
                    phase: .up, growthKeys: []), startsSession: false))
            time += [6, 14].contains(index) ? 600 : [300, 380, 340][index % 3]
        }
        let history = [firstKey: seed, lastKey: sample]
        let period = KeyboardTrackingPeriod(history: history, calendar: calendar, dateKeyFormatter: formatter)!
        let presentation = GrowthKeyboardPresentation(timeline: CumulativeKeyboardTimeline.build(history: history),
            period: period, now: now, calendar: calendar)!
        return KeyReplayExample(presentation: presentation, recordedDayKey: lastKey,
            day: KeyReplayDay(entries: entries, hasUnreadableChunks: false))
    }
}
#endif
