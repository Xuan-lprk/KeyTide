import Foundation

@objc public protocol KeytideHelperProtocol {
    func handshake(clientInterfaceVersion: Int,
                   reply: @escaping (_ helperVersion: Int,
                                     _ accessibilityGranted: Bool) -> Void)

    func startMonitoring(reply: @escaping (_ ok: Bool, _ errorCode: Int) -> Void)

    func stopMonitoring()

    /// Retained for version detection by legacy clients. v4 uses controlInput.
    func setReplayRecordingEnabled(_ enabled: Bool, reply: @escaping (Bool) -> Void)

    /// 让 helper 调一次 `AXIsProcessTrustedWithOptions(prompt: true)`，目的是把
    /// 自己注册进系统设置 → 隐私与安全性 → 辅助功能 的列表。副作用：首次调用会弹一个系统级
    /// "KeytideHelper 希望……"的确认框（含"打开系统设置"按钮）。回调 true 表示已经授权。
    func promptAccessibility(reply: @escaping (_ granted: Bool) -> Void)

    func helperBundleURL(reply: @escaping (_ path: String) -> Void)

    func controlTrackpad(_ command: Int, reply: @escaping (Int, Bool) -> Void)
    func controlInput(_ command: Int, argument: Data, reply: @escaping (Data?, Bool) -> Void)
}

@objc public protocol KeytideEventSinkProtocol {
    func receiveEvent(_ payload: [String: Any])
    @objc optional func receiveTrackpadPreview(_ frames: Data)
    @objc optional func receiveTrackpadStatus(_ status: Int)
    @objc optional func receiveInputSnapshot(_ snapshot: Data)
    @objc optional func receiveKeyboardReplayStatus(_ status: Int)
    @objc optional func receiveThresholdNotification(_ isKeyPress: Bool, count: Int, threshold: Int)
}

enum InputControl: Int {
    case backgroundStatus, enableBackground, disableBackground, resetStats, mergeStats, overwriteStats
    case updateAttribution, enableKeyboardReplay, disableKeyboardReplay, keyboardReplayStatus, flushKeyboardReplay, deleteKeyboardReplay
    case beginCalibration, calibrationPixels, cancelCalibration
    case updateThresholdPreferences
}

struct BackgroundInputStatus: Codable {
    let allowed: Bool
    let listening: Bool
}

enum BackgroundInputPreference {
    static let requestedKey = "backgroundInput.requested.v1"
    static let appliedKey = "helper.backgroundInputAllowed.v1"

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: requestedKey) as? Bool
            ?? defaults.object(forKey: appliedKey) as? Bool
            ?? true
    }
}

struct InputCalibrationResult: Codable {
    let pixels: Double
    let factor: Double?
}

struct InputCalibrationProgress: Codable {
    let moving: Bool
    let pixels: Double
}

struct InputThresholdPreferences: Codable {
    let enabled: Bool
    let keyPresses: Int
    let clicks: Int
}

enum TrackpadControl: Int {
    case status, enable, disable, startPreview, stopPreview, flush, delete
}

enum TrackpadRecordingStatus: Int {
    case off, recording, failed, suspended
}
