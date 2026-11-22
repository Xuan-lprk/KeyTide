import Foundation
import CryptoKit

// Compile with KeytideHelper/TrackpadRecording.swift. No App, device, Keychain or
// user history is opened. Temporary encrypted synthetic records are removed.
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let key = SymmetricKey(size: .bits256), day = "2026-11-16"
let aad = Data(("Keytide.Trackpad.v1/" + day).utf8)
var files: [URL] = []
let count = 4000 * 128
for chunk in 0..<4000 {
    let frames = (0..<128).map { index -> TrackpadFrame in
        let ordinal = chunk * 128 + index
        return TrackpadFrame(sourceTime: Double(ordinal) / 120, ordinal: Int32(ordinal), contacts: [])
    }
    let data = try AES.GCM.seal(JSONEncoder().encode(frames), using: key, authenticating: aad).combined!
    let file = folder.appendingPathComponent(String(format: "00000000000000000001-session-%08d.ktp", chunk))
    try data.write(to: file); files.append(file)
}
func awaitResult<T>(_ call: (@escaping (T) -> Void) -> Void) -> T {
    var result: T?
    call { result = $0 }
    let deadline = Date().addingTimeInterval(90)
    while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    precondition(result != nil, "Timed out")
    return result!
}
let reader = TrackpadReplayReader(files: files, key: key, day: day)
precondition(awaitResult { reader.prepare(completion: $0) })
var received = 0, expected: Int32 = 0, done = false
let start = ProcessInfo.processInfo.systemUptime
while !done {
    let result: ([TrackpadFrame], Bool, Bool) = awaitResult { callback in
        reader.take(through: 10) { callback(($0, $1, $2)) }
    }
    precondition(!result.2 && result.0.count <= 128)
    for frame in result.0 {
        // First frame is the explicit session boundary, followed by ordinal 0.
        if received > 0 { precondition(frame.ordinal == expected); expected += 1 }
        received += 1
    }
    done = result.1
}
precondition(received == count + 1)
reader.cancel()
let cancelled: ([TrackpadFrame], Bool, Bool) = awaitResult { cb in reader.take(through: 10) { cb(($0,$1,$2)) } }
precondition(cancelled.0.isEmpty && cancelled.1)
let corrupt = folder.appendingPathComponent("corrupt.ktp"); try Data([1,2,3]).write(to: corrupt)
let bad = TrackpadReplayReader(files: [corrupt], key: key, day: day)
precondition(!awaitResult { bad.prepare(completion: $0) })
let wrongDay = TrackpadReplayReader(files: [files[0]], key: key, day: "2026-11-15")
precondition(!awaitResult { wrongDay.prepare(completion: $0) })
print("PASS: \(count) source frames in order, <=128 delivery batch, cancellation, corrupt chunk and day authentication rejection")
print("Delivery without drawing seconds: \(ProcessInfo.processInfo.systemUptime-start); not GUI timing or energy acceptance")
