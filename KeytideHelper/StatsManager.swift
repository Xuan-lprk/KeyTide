import Foundation
import Cocoa
import Compression

private func canonicalKeyPart(_ rawKeyPart: String) -> String {
    let trimmed = rawKeyPart.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    switch trimmed.uppercased() {
    case "FN", "FUNCTION", "KEY63", "KEY179", "GLOBE", "🌐":
        return "Fn"
    default:
        return trimmed
    }
}

private func canonicalKeyName(_ keyName: String) -> String {
    if !keyName.contains("+") { return canonicalKeyPart(keyName) }
    let trimmed = keyName.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "+" {
        return "+"
    }

    // Handle trailing "++" which means the base key is literal "+".
    // e.g. "Cmd++" → ["Cmd", "+"]
    var raw = trimmed
    var trailingPlus = false
    if raw.hasSuffix("++") {
        raw = String(raw.dropLast())   // "Cmd++" → "Cmd+"
        trailingPlus = true
    }

    var rawComponents = raw
        .split(separator: "+")
        .map { canonicalKeyPart(String($0)) }
        .filter { !$0.isEmpty }

    if trailingPlus {
        rawComponents.append("+")
    }

    guard !rawComponents.isEmpty else { return "" }

    var orderedComponents: [String] = []
    var seenComponents: Set<String> = []
    for component in rawComponents {
        if seenComponents.insert(component).inserted {
            orderedComponents.append(component)
        }
    }

    return orderedComponents.joined(separator: "+")
}

/// 统计数据管理器 - 单例模式
class StatsManager {
    enum ThresholdMetric {
        case keyPresses
        case clicks
    }

    struct Environment {
        let userDefaults: UserDefaults
        let now: () -> Date
        let calendar: () -> Calendar
        let makeDateKeyFormatter: () -> DateFormatter
        let notificationCenter: NotificationCenter
        let schedulesAutomaticWork: Bool
        let sendThresholdNotification: (ThresholdMetric, Int, Int) -> Void
    }

    struct CaptureSnapshot: Codable {
        let current: DailyStats
        let history: [String: DailyStats]?
        let kps: Int
        let cps: Int
        let sampledAt: TimeInterval
        let calibrationFactor: Double
    }

    /// Decodes the live fields without expanding the potentially large history object.
    /// The Helper's existing CaptureSnapshot wire format is unchanged.
    struct CaptureUpdate: Decodable {
        let current: DailyStats
        let kps: Int
        let cps: Int
        let sampledAt: TimeInterval
        let calibrationFactor: Double
        let containsHistory: Bool

        private enum CodingKeys: String, CodingKey {
            case current, history, kps, cps, sampledAt, calibrationFactor
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            current = try values.decode(DailyStats.self, forKey: .current)
            kps = try values.decode(Int.self, forKey: .kps)
            cps = try values.decode(Int.self, forKey: .cps)
            sampledAt = try values.decode(TimeInterval.self, forKey: .sampledAt)
            calibrationFactor = try values.decode(Double.self, forKey: .calibrationFactor)
            containsHistory = try values.contains(.history) && !values.decodeNil(forKey: .history)
        }
    }

    private struct CaptureHistory<History: Decodable>: Decodable {
        let history: History
    }

    /// The menu keeps the latest full Helper message for reopening pages and exports.
    /// Large messages are packed once on receipt, before delivery to the main thread.
    enum HistoryPayload {
        case plain(Data)
        case lz4(Data, originalCount: Int)

        init(_ data: Data) {
            guard data.count >= 256 * 1024 else { self = .plain(data); return }
            // Keep compression only if it saves at least a quarter of the message.
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: data.count - data.count / 4)
            defer { buffer.deallocate() }
            let written = data.withUnsafeBytes { source in
                compression_encode_buffer(buffer.baseAddress!, buffer.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZ4)
            }
            self = written > 0 ? .lz4(Data(bytes: buffer.baseAddress!, count: written), originalCount: data.count) : .plain(data)
        }

        var data: Data? {
            switch self {
            case let .plain(data): return data
            case let .lz4(packed, originalCount):
                var unpacked = Data(count: originalCount)
                let written = unpacked.withUnsafeMutableBytes { destination in
                    packed.withUnsafeBytes { source in
                        compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, originalCount,
                            source.bindMemory(to: UInt8.self).baseAddress!, packed.count, nil, COMPRESSION_LZ4)
                    }
                }
                return written == originalCount ? unpacked : nil
            }
        }
    }

    private struct ChartDay: Decodable {
        let totals: DailyStats

        init(from decoder: Decoder) throws {
            totals = try DailyStats(from: decoder, breakdowns: .none)
        }
    }

    private struct GlobalDay: Decodable {
        let stats: DailyStats

        init(from decoder: Decoder) throws {
            stats = try DailyStats(from: decoder, breakdowns: .global)
        }
    }

    /// Materialize just the requested days from either stored history or a Helper snapshot.
    private struct SelectedDays: Decodable {
        private typealias Lookup = (keys: Set<String>, formatter: DateFormatter, calendar: Calendar)
        private static let lookupKey = CodingUserInfoKey(rawValue: "Keytide.storedDayLookup")!

        private struct DayKey: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        let days: [String: DailyStats]

        static func read(from data: Data, envelope: Bool, keys: Set<String>,
                         formatter: DateFormatter, calendar: Calendar) -> [String: DailyStats]? {
            let decoder = JSONDecoder()
            decoder.userInfo[lookupKey] = (keys, formatter, calendar) as Lookup
            if envelope { return try? decoder.decode(CaptureHistory<Self>.self, from: data).history.days }
            return try? decoder.decode(Self.self, from: data).days
        }

        init(from decoder: Decoder) throws {
            guard let lookup = decoder.userInfo[Self.lookupKey] as? Lookup else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing day lookup"))
            }
            let entries = try decoder.container(keyedBy: DayKey.self)
            var selected: [String: DailyStats] = [:]
            for key in lookup.keys {
                let codingKey = DayKey(stringValue: key)
                if entries.contains(codingKey) { selected[key] = try entries.decode(DailyStats.self, forKey: codingKey) }
            }
            if selected.count < lookup.keys.count {
                // Valid date keys win. Among legacy keys the first lexical match wins.
                let formatter = lookup.formatter
                let legacy = entries.allKeys.filter { key in
                    guard let date = formatter.date(from: key.stringValue) else { return true }
                    return formatter.string(from: date) != key.stringValue
                }
                for key in legacy.sorted(by: { $0.stringValue < $1.stringValue }) {
                    let day = try entries.decode(DailyStats.self, forKey: key)
                    let fallback = formatter.string(from: lookup.calendar.startOfDay(for: day.date))
                    if lookup.keys.contains(fallback), selected[fallback] == nil { selected[fallback] = day }
                    if selected.count == lookup.keys.count { break }
                }
            }
            days = selected
        }
    }

    enum ImportMode {
        case overwrite
        case merge
    }

    enum MouseDistanceCalibrationResult {
        case success(pixels: Double, factor: Double)
        case failure(pixels: Double)
    }
    
    private let environment: Environment
    private let ownsCaptureStore: Bool
    private let batchesCaptureUpdates: Bool
    private var historyNeedsSave = true
    private var receivedRates: (kps: Int, cps: Int, at: TimeInterval)?
    private var userDefaults: UserDefaults { environment.userDefaults }
    private let statsKey = "dailyStats"
    private let historyKey = "dailyStatsHistory"
    private let showKeyPressesKey = "showKeyPressesInMenuBar"
    private let showMouseClicksKey = "showMouseClicksInMenuBar"
    private let minimalMenuBarModeKey = "minimalMenuBarMode"
    private let appStatsEnabledKey = "appStatsEnabled"
    private let keyPressNotifyThresholdKey = "keyPressNotifyThreshold"
    private let clickNotifyThresholdKey = "clickNotifyThreshold"
    private let notificationsEnabledKey = "notificationsEnabled"
    private let enableDynamicIconColorKey = "enableDynamicIconColor"
    private let dynamicIconColorStyleKey = "dynamicIconColorStyle"
    private let dynamicIconColorWindowKey = "dynamicIconColorWindow"
    private let mouseDistanceCalibrationFactorKey = "mouseDistanceCalibrationFactor"
    private let dateFormatter: DateFormatter
    private var history: [String: DailyStats] = [:]
    private var captureHistoryPayload: HistoryPayload?
    private var presentationHistory: [String: DailyStats]?
    private var recentAppHistory: (keys: Set<String>, days: [String: DailyStats])?
    private var globalHistory: [String: DailyStats]?
    private var chartHistory: [String: DailyStats]?
    private var saveTimer: Timer?
    private var statsUpdateTimer: Timer?
    private var midnightCheckTimer: Timer?
    private let saveInterval: TimeInterval = 2.0
    private let statsUpdateDebounceInterval: TimeInterval = 0.3
    
    private var inputRateWindowSeconds: TimeInterval {
        let val = userDefaults.double(forKey: dynamicIconColorWindowKey)
        return val > 0 ? val : 3.0
    }
    
    private let inputRateBucketInterval: TimeInterval = 0.5
    private let inputRateApmThresholds: [Double] = [0, 80, 160, 240]
    private let inputRateLock = NSLock()

    // KPS/CPS 峰值追踪（滑动窗口，1 秒，单调时钟）
    private let statsStateLock = NSLock()
    private var recentKeyTimestamps: [TimeInterval] = []  // ProcessInfo.systemUptime values
    private var recentClickTimestamps: [TimeInterval] = []  // ProcessInfo.systemUptime values
    private var keyTimestampsHead: Int = 0
    private var clickTimestampsHead: Int = 0
    private var isReadyForUpdates = false
    private lazy var inputRateBuckets: [Int] = {
        let bucketCount = max(1, Int(inputRateWindowSeconds / inputRateBucketInterval))
        return Array(repeating: 0, count: bucketCount)
    }()
    private var inputRateBucketIndex = 0
    private var inputRateTimer: Timer?
    private var inputRateStartTime: Date?
    private(set) var currentInputRatePerSecond: Double = 0
    private(set) var currentIconTintColor: NSColor?
    // Shared with input callbacks. The callback itself is delivered on main.
    private let menuBarPresentationLock = NSLock()
    private var menuBarHandler: (() -> Void)?
    private var menuBarUpdateQueued = false
    var menuBarUpdateHandler: (() -> Void)? {
        get {
            menuBarPresentationLock.lock()
            defer { menuBarPresentationLock.unlock() }
            return menuBarHandler
        }
        set {
            precondition(Thread.isMainThread)
            menuBarPresentationLock.lock()
            let visibilityChanged = (menuBarHandler == nil) != (newValue == nil)
            menuBarHandler = newValue
            menuBarPresentationLock.unlock()
            if visibilityChanged && enableDynamicIconColor {
                refreshInputRateTracking()
            }
        }
    }
    private var statsUpdateHandlers: [UUID: () -> Void] = [:]

    private var cachedMouseDistanceCalibrationFactor: Double = 1.0
    private let mouseDistanceCalibrationLock = NSLock()
    private enum MouseDistanceCalibrationState {
        case idle
        case armed
        case recording
    }
    private var mouseDistanceCalibrationState: MouseDistanceCalibrationState = .idle
    private var mouseDistanceCalibrationPixels: Double = 0
    private var mouseDistanceCalibrationTargetMeters: Double = 0
    private var mouseDistanceCalibrationMinPixels: Double = 50
    private var mouseDistanceCalibrationCompletion: ((MouseDistanceCalibrationResult) -> Void)?
    
    /// 设置：是否在菜单栏显示按键数
    var showKeyPressesInMenuBar: Bool {
        didSet {
            userDefaults.set(showKeyPressesInMenuBar, forKey: showKeyPressesKey)
            notifyMenuBarUpdate()
        }
    }
    
    /// 设置：是否在菜单栏显示点击数
    var showMouseClicksInMenuBar: Bool {
        didSet {
            userDefaults.set(showMouseClicksInMenuBar, forKey: showMouseClicksKey)
            notifyMenuBarUpdate()
        }
    }

    /// 设置：是否启用极简菜单栏模式
    var minimalMenuBarMode: Bool {
        didSet {
            userDefaults.set(minimalMenuBarMode, forKey: minimalMenuBarModeKey)
            notifyMenuBarUpdate()
        }
    }

    /// 设置：是否开启按应用统计
    var appStatsEnabled: Bool {
        didSet {
            userDefaults.set(appStatsEnabled, forKey: appStatsEnabledKey)
            notifyStatsUpdate()
        }
    }

    /// 设置：是否开启统计通知
    var notificationsEnabled: Bool {
        didSet {
            userDefaults.set(notificationsEnabled, forKey: notificationsEnabledKey)
            if notificationsEnabled {
                updateNotificationBaselines()
            }
        }
    }

    /// 设置：按键通知阈值
    var keyPressNotifyThreshold: Int {
        didSet {
            userDefaults.set(keyPressNotifyThreshold, forKey: keyPressNotifyThresholdKey)
            updateKeyPressNotificationBaseline()
        }
    }

    /// 设置：点击通知阈值
    var clickNotifyThreshold: Int {
        didSet {
            userDefaults.set(clickNotifyThreshold, forKey: clickNotifyThresholdKey)
            updateClickNotificationBaseline()
        }
    }

    /// 设置：动态图标颜色时间窗口（秒）
    var dynamicIconColorWindow: TimeInterval {
        get {
            let val = userDefaults.double(forKey: dynamicIconColorWindowKey)
            return val > 0 ? val : 3.0
        }
        set {
            let newVal = max(1.0, newValue) // Minimum 1 second
            userDefaults.set(newVal, forKey: dynamicIconColorWindowKey)
            
            // Re-initialize buckets if enabled
            if enableDynamicIconColor {
                let applyChanges = { [weak self] in
                    guard let self = self else { return }
                    self.refreshInputRateTracking()
                }
                if Thread.isMainThread {
                    applyChanges()
                } else {
                    DispatchQueue.main.async(execute: applyChanges)
                }
            }
        }
    }

    /// 设置：是否启用动态图标颜色
    var enableDynamicIconColor: Bool {
        didSet {
            userDefaults.set(enableDynamicIconColor, forKey: enableDynamicIconColorKey)
            let applyChanges: () -> Void = { [weak self] in
                self?.refreshInputRateTracking()
            }
            if Thread.isMainThread {
                applyChanges()
                return
            }
            DispatchQueue.main.async(execute: applyChanges)
        }
    }

    /// 设置：鼠标距离校准系数（默认 1.0）
    var mouseDistanceCalibrationFactor: Double {
        get { cachedMouseDistanceCalibrationFactor }
        set {
            let clamped = max(0.01, newValue)
            guard cachedMouseDistanceCalibrationFactor != clamped else { return }
            cachedMouseDistanceCalibrationFactor = clamped
            userDefaults.set(clamped, forKey: mouseDistanceCalibrationFactorKey)
            notifyMenuBarUpdate()
            notifyStatsUpdate()
        }
    }

    /// 每像素对应的物理距离（米）
    var mouseDistanceMetersPerPixel: Double {
        return baseMetersPerPixel * mouseDistanceCalibrationFactor
    }

    private var lastNotifiedKeyPresses: Int = 0
    private var lastNotifiedClicks: Int = 0
    
    /// 当前统计数据
    private(set) var currentStats: DailyStats {
        didSet {
            guard isReadyForUpdates else { return }
            scheduleSave()
        }
    }
    
    /// 上次鼠标位置（用于计算移动距离）
    var lastMousePosition: NSPoint?
    
    init(environment: Environment,
         ownsCaptureStore: Bool = true,
         batchesCaptureUpdates: Bool = false,
         usesDynamicMenuBarIconColor: Bool = true) {
        self.environment = environment
        self.ownsCaptureStore = ownsCaptureStore
        self.batchesCaptureUpdates = batchesCaptureUpdates
        let defaults = environment.userDefaults
        dateFormatter = environment.makeDateKeyFormatter()

        // 加载设置（按键/点击默认 true，通知/动态图标默认 false）
        showKeyPressesInMenuBar = defaults.object(forKey: showKeyPressesKey) as? Bool ?? true
        showMouseClicksInMenuBar = defaults.object(forKey: showMouseClicksKey) as? Bool ?? true
        minimalMenuBarMode = defaults.object(forKey: minimalMenuBarModeKey) as? Bool ?? false
        appStatsEnabled = defaults.object(forKey: appStatsEnabledKey) as? Bool ?? true
        notificationsEnabled = defaults.object(forKey: notificationsEnabledKey) as? Bool ?? false
        keyPressNotifyThreshold = defaults.object(forKey: keyPressNotifyThresholdKey) as? Int ?? 1000
        clickNotifyThreshold = defaults.object(forKey: clickNotifyThresholdKey) as? Int ?? 1000
        enableDynamicIconColor = usesDynamicMenuBarIconColor
            && (defaults.object(forKey: enableDynamicIconColorKey) as? Bool ?? false)
        let storedCalibration = defaults.double(forKey: mouseDistanceCalibrationFactorKey)
        cachedMouseDistanceCalibrationFactor = storedCalibration > 0 ? storedCalibration : 1.0

        // 先初始化 currentStats 为默认值
        let calendar = environment.calendar()
        let today = calendar.startOfDay(for: environment.now())
        currentStats = DailyStats(date: today)
        if ownsCaptureStore {
            history = normalizedHistory(loadHistory(DailyStats.self))
        }

        // 优先加载 dailyStats；如果缺失或不是今天，回退到 history 里的今天数据。
        let loadedCurrent = loadStats().map(normalizedDailyStats)
        if batchesCaptureUpdates, let loadedCurrent, !calendar.isDate(loadedCurrent.date, inSameDayAs: today) {
            history[dateFormatter.string(from: loadedCurrent.date)] = loadedCurrent
        }
        if let savedStats = loadedCurrent, calendar.isDate(savedStats.date, inSameDayAs: today) {
            currentStats = savedStats
        } else {
            let todayKey = dateFormatter.string(from: today)
            // Recover today's totals from older installations without retaining their
            // decoded history in a menu-only process.
            if ownsCaptureStore {
                if let day = history[todayKey] { currentStats = day }
            } else if let data = defaults.data(forKey: historyKey),
                      let day = SelectedDays.read(from: data, envelope: false, keys: [todayKey], formatter: dateFormatter, calendar: calendar)?[todayKey] {
                currentStats = normalizedDailyStats(day)
                currentStats.date = today
            }
        }

        updateNotificationBaselines()
        
        isReadyForUpdates = true
        saveStats()
        if environment.schedulesAutomaticWork && ownsCaptureStore {
            setupMidnightReset()

        }
    }

    deinit {
        saveTimer?.invalidate()
        statsUpdateTimer?.invalidate()
        midnightCheckTimer?.invalidate()
        inputRateTimer?.invalidate()

    }
    
    // MARK: - 数据更新方法

    /// 调用前必须持有 statsStateLock
    private func updateAppStatsLocked(for identity: AppIdentity, update: (inout AppStats) -> Void) {
        guard appStatsEnabled else { return }
        let bundleId = identity.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleId.isEmpty else { return }
        func record(in stats: inout AppStats) {
            stats.updateDisplayName(identity.displayName)
            update(&stats)
        }
        record(in: &currentStats.appStats[bundleId, default: AppStats(bundleId: bundleId, displayName: identity.displayName)])
    }

    func incrementKeyPresses(keyName: String? = nil, appIdentity: AppIdentity? = nil) {
        statsStateLock.lock()
        ensureCurrentDayLocked()
        currentStats.keyPresses = safeAdd(currentStats.keyPresses, 1)
        let canonicalName = keyName.map(canonicalKeyName).flatMap { $0.isEmpty ? nil : $0 }
        if let canonicalName {
            currentStats.keyPressCounts[canonicalName] = safeAdd(currentStats.keyPressCounts[canonicalName, default: 0], 1)
        }
        if let appIdentity = appIdentity {
            updateAppStatsLocked(for: appIdentity) { stats in
                stats.recordKeyPress(keyName: canonicalName)
            }
        }
        statsStateLock.unlock()
        registerInputEvent()
        recordKeyForPeakKPS()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
        notifyKeyPressThresholdIfNeeded()
    }

    func incrementLeftClicks(appIdentity: AppIdentity? = nil) {
        statsStateLock.lock()
        ensureCurrentDayLocked()
        currentStats.leftClicks = safeAdd(currentStats.leftClicks, 1)
        if let appIdentity = appIdentity {
            updateAppStatsLocked(for: appIdentity) { stats in
                stats.recordLeftClick()
            }
        }
        statsStateLock.unlock()
        registerInputEvent()
        recordClickForPeakCPS()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
        notifyClickThresholdIfNeeded()
    }

    func incrementRightClicks(appIdentity: AppIdentity? = nil) {
        statsStateLock.lock()
        ensureCurrentDayLocked()
        currentStats.rightClicks = safeAdd(currentStats.rightClicks, 1)
        if let appIdentity = appIdentity {
            updateAppStatsLocked(for: appIdentity) { stats in
                stats.recordRightClick()
            }
        }
        statsStateLock.unlock()
        registerInputEvent()
        recordClickForPeakCPS()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
        notifyClickThresholdIfNeeded()
    }

    func incrementMiddleClicks(appIdentity: AppIdentity? = nil) {
        statsStateLock.lock()
        ensureCurrentDayLocked()
        currentStats.middleClicks = safeAdd(currentStats.middleClicks, 1)
        if let appIdentity {
            updateAppStatsLocked(for: appIdentity) { $0.recordMiddleClick() }
        }
        statsStateLock.unlock()
        registerInputEvent()
        recordClickForPeakCPS()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
        notifyClickThresholdIfNeeded()
    }

    func incrementSideBackClicks(appIdentity: AppIdentity? = nil) {
        statsStateLock.lock()
        ensureCurrentDayLocked()
        currentStats.sideBackClicks = safeAdd(currentStats.sideBackClicks, 1)
        if let appIdentity = appIdentity {
            updateAppStatsLocked(for: appIdentity) { stats in
                stats.recordSideBackClick()
            }
        }
        statsStateLock.unlock()
        registerInputEvent()
        recordClickForPeakCPS()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
        notifyClickThresholdIfNeeded()
    }

    func incrementSideForwardClicks(appIdentity: AppIdentity? = nil) {
        statsStateLock.lock()
        ensureCurrentDayLocked()
        currentStats.sideForwardClicks = safeAdd(currentStats.sideForwardClicks, 1)
        if let appIdentity = appIdentity {
            updateAppStatsLocked(for: appIdentity) { stats in
                stats.recordSideForwardClick()
            }
        }
        statsStateLock.unlock()
        registerInputEvent()
        recordClickForPeakCPS()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
        notifyClickThresholdIfNeeded()
    }
    
    func addMouseDistance(_ distance: Double) {
        statsStateLock.lock()
        ensureCurrentDayLocked()
        currentStats.mouseDistance += distance
        statsStateLock.unlock()
        scheduleDebouncedStatsUpdate()
    }

    func beginMouseDistanceCalibration(knownMeters: Double,
                                       minPixels: Double = 50,
                                       completion: @escaping (MouseDistanceCalibrationResult) -> Void) {
        mouseDistanceCalibrationLock.lock()
        mouseDistanceCalibrationTargetMeters = max(0, knownMeters)
        mouseDistanceCalibrationMinPixels = max(0, minPixels)
        mouseDistanceCalibrationCompletion = completion
        mouseDistanceCalibrationState = .armed
        mouseDistanceCalibrationPixels = 0
        mouseDistanceCalibrationLock.unlock()
        lastMousePosition = nil
    }

    func cancelMouseDistanceCalibration() {
        mouseDistanceCalibrationLock.lock()
        mouseDistanceCalibrationState = .idle
        mouseDistanceCalibrationPixels = 0
        mouseDistanceCalibrationTargetMeters = 0
        mouseDistanceCalibrationCompletion = nil
        mouseDistanceCalibrationLock.unlock()
    }

    func handleMouseDistanceCalibrationKeyPress() -> Bool {
        var completion: ((MouseDistanceCalibrationResult) -> Void)?
        var result: MouseDistanceCalibrationResult?

        mouseDistanceCalibrationLock.lock()
        switch mouseDistanceCalibrationState {
        case .idle:
            mouseDistanceCalibrationLock.unlock()
            return false
        case .armed:
            mouseDistanceCalibrationState = .recording
            mouseDistanceCalibrationPixels = 0
            mouseDistanceCalibrationLock.unlock()
            lastMousePosition = nil
            return true
        case .recording:
            mouseDistanceCalibrationState = .idle
            let pixels = mouseDistanceCalibrationPixels
            let targetMeters = mouseDistanceCalibrationTargetMeters
            let minPixels = mouseDistanceCalibrationMinPixels
            completion = mouseDistanceCalibrationCompletion
            mouseDistanceCalibrationCompletion = nil
            mouseDistanceCalibrationPixels = 0
            mouseDistanceCalibrationTargetMeters = 0
            mouseDistanceCalibrationLock.unlock()

            if targetMeters > 0, pixels >= minPixels {
                let measuredMetersPerPixel = targetMeters / pixels
                let factor = measuredMetersPerPixel / baseMetersPerPixel
                mouseDistanceCalibrationFactor = factor
                result = .success(pixels: pixels, factor: factor)
            } else {
                result = .failure(pixels: pixels)
            }
        }

        if let completion = completion, let result = result {
            DispatchQueue.main.async {
                completion(result)
            }
        }
        return true
    }

    func recordMouseDistanceCalibration(_ distance: Double) {
        mouseDistanceCalibrationLock.lock()
        if mouseDistanceCalibrationState == .recording {
            mouseDistanceCalibrationPixels += distance
        }
        mouseDistanceCalibrationLock.unlock()
    }

    var isMouseDistanceCalibrating: Bool {
        mouseDistanceCalibrationLock.lock()
        let value = mouseDistanceCalibrationState == .recording
        mouseDistanceCalibrationLock.unlock()
        return value
    }

    var isMouseDistanceCalibrationActive: Bool {
        mouseDistanceCalibrationLock.lock()
        let value = mouseDistanceCalibrationState != .idle
        mouseDistanceCalibrationLock.unlock()
        return value
    }

    func currentMouseDistanceCalibrationPixels() -> Double {
        mouseDistanceCalibrationLock.lock()
        let pixels = mouseDistanceCalibrationPixels
        mouseDistanceCalibrationLock.unlock()
        return pixels
    }
    
    func addScrollDistance(_ distance: Double, appIdentity: AppIdentity? = nil) {
        statsStateLock.lock()
        ensureCurrentDayLocked()
        currentStats.scrollDistance += abs(distance)
        if let appIdentity = appIdentity {
            updateAppStatsLocked(for: appIdentity) { stats in
                stats.addScrollDistance(distance)
            }
        }
        statsStateLock.unlock()
        scheduleDebouncedStatsUpdate()
    }

    func incrementScrollSessions(appIdentity: AppIdentity? = nil) {
        statsStateLock.lock()
        ensureCurrentDayLocked()
        currentStats.scrollSessions = aggregateScrollSessionCounts([currentStats.scrollSessions, 1])
        if let appIdentity = appIdentity {
            updateAppStatsLocked(for: appIdentity) { stats in
                stats.recordScrollSession()
            }
        }
        statsStateLock.unlock()
        scheduleDebouncedStatsUpdate()
    }

    // MARK: - 输入速率

    private func registerInputEvent(count: Int = 1) {
        guard count > 0, enableDynamicIconColor, menuBarUpdateHandler != nil else { return }
        inputRateLock.lock()
        inputRateBuckets[inputRateBucketIndex] = safeAdd(inputRateBuckets[inputRateBucketIndex], count)
        inputRateLock.unlock()
    }

    // MARK: - KPS/CPS 峰值追踪

    /// Trailing 1-second sliding-window count of key events.
    /// Peak KPS = max trailing 1-second sliding-window count observed today.
    func recordKeyForPeakKPS() {
        let now = ProcessInfo.processInfo.systemUptime
        let cutoff = now - 1.0
        statsStateLock.lock()
        recentKeyTimestamps.append(now)
        pruneKeyTimestamps(before: cutoff)
        let currentKPS = recentKeyTimestamps.count - keyTimestampsHead
        if currentKPS > currentStats.peakKPS {
            currentStats.peakKPS = currentKPS
        }
        statsStateLock.unlock()
    }

    /// Trailing 1-second sliding-window count of click events.
    /// Peak CPS = max trailing 1-second sliding-window count observed today.
    func recordClickForPeakCPS() {
        let now = ProcessInfo.processInfo.systemUptime
        let cutoff = now - 1.0
        statsStateLock.lock()
        recentClickTimestamps.append(now)
        pruneClickTimestamps(before: cutoff)
        let currentCPS = recentClickTimestamps.count - clickTimestampsHead
        if currentCPS > currentStats.peakCPS {
            currentStats.peakCPS = currentCPS
        }
        statsStateLock.unlock()
    }

    // MARK: - 实时 KPS/CPS 查询

    /// 获取当前实时 KPS（过去 1 秒内的按键数）
    func getCurrentKPS() -> Int {
        let cutoff = ProcessInfo.processInfo.systemUptime - 1.0
        statsStateLock.lock()
        pruneKeyTimestamps(before: cutoff)
        let count = recentKeyTimestamps.count - keyTimestampsHead
        statsStateLock.unlock()
        return count
    }

    /// 获取当前实时 CPS（过去 1 秒内的点击数）
    func getCurrentCPS() -> Int {
        let cutoff = ProcessInfo.processInfo.systemUptime - 1.0
        statsStateLock.lock()
        pruneClickTimestamps(before: cutoff)
        let count = recentClickTimestamps.count - clickTimestampsHead
        statsStateLock.unlock()
        return count
    }

    /// 获取当前 KPS/CPS 和峰值的快照（线程安全）
    func currentRatesSnapshot() -> (currentKPS: Int, currentCPS: Int, peakKPS: Int, peakCPS: Int) {
        let cutoff = ProcessInfo.processInfo.systemUptime - 1.0
        statsStateLock.lock()
        if !ownsCaptureStore {
            let fresh = receivedRates.flatMap { $0.at > cutoff ? $0 : nil }
            let values = (fresh?.kps ?? 0, fresh?.cps ?? 0, currentStats.peakKPS, currentStats.peakCPS)
            statsStateLock.unlock()
            return values
        }
        pruneKeyTimestamps(before: cutoff)
        pruneClickTimestamps(before: cutoff)
        let kps = recentKeyTimestamps.count - keyTimestampsHead
        let cps = recentClickTimestamps.count - clickTimestampsHead
        let peakKPS = currentStats.peakKPS
        let peakCPS = currentStats.peakCPS
        statsStateLock.unlock()
        return (kps, cps, peakKPS, peakCPS)
    }

    // MARK: - 滑动窗口内部方法（调用前必须持有 statsStateLock）

    private func pruneKeyTimestamps(before cutoff: TimeInterval) {
        while keyTimestampsHead < recentKeyTimestamps.count && recentKeyTimestamps[keyTimestampsHead] <= cutoff {
            keyTimestampsHead += 1
        }
        compactKeyTimestampsIfNeeded()
    }

    private func pruneClickTimestamps(before cutoff: TimeInterval) {
        while clickTimestampsHead < recentClickTimestamps.count && recentClickTimestamps[clickTimestampsHead] <= cutoff {
            clickTimestampsHead += 1
        }
        compactClickTimestampsIfNeeded()
    }

    private func compactKeyTimestampsIfNeeded() {
        if keyTimestampsHead > 128 {
            recentKeyTimestamps.removeFirst(keyTimestampsHead)
            keyTimestampsHead = 0
        }
    }

    private func compactClickTimestampsIfNeeded() {
        if clickTimestampsHead > 128 {
            recentClickTimestamps.removeFirst(clickTimestampsHead)
            clickTimestampsHead = 0
        }
    }

    private func resetInputRateBuckets() {
        inputRateLock.lock()
        let bucketCount = max(1, Int(inputRateWindowSeconds / inputRateBucketInterval))
        inputRateBuckets = Array(repeating: 0, count: bucketCount)
        inputRateBucketIndex = 0
        inputRateLock.unlock()
    }

    private func refreshInputRateTracking() {
        stopInputRateTracking()
        currentInputRatePerSecond = 0
        currentIconTintColor = nil
        guard environment.schedulesAutomaticWork, enableDynamicIconColor, menuBarUpdateHandler != nil else {
            notifyMenuBarUpdate()
            return
        }

        resetInputRateBuckets()
        inputRateStartTime = environment.now()
        inputRateTimer = Timer.scheduledTimer(withTimeInterval: inputRateBucketInterval, repeats: true) { [weak self] _ in
            self?.advanceInputRateBucket()
        }
        if let timer = inputRateTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopInputRateTracking() {
        inputRateStartTime = nil
        inputRateTimer?.invalidate()
        inputRateTimer = nil
    }

    private func advanceInputRateBucket() {
        inputRateLock.lock()
        inputRateBucketIndex = (inputRateBucketIndex + 1) % inputRateBuckets.count
        inputRateBuckets[inputRateBucketIndex] = 0
        inputRateLock.unlock()
        updateCurrentInputRate()
    }

    private func updateCurrentInputRate() {
        inputRateLock.lock()
        let totalEvents = inputRateBuckets.reduce(0, safeAdd)
        inputRateLock.unlock()
        
        var effectiveWindow = inputRateWindowSeconds
        // Adjust window for initial ramp-up to avoid diluted rates when monitoring just started
        if let startTime = inputRateStartTime {
            let elapsed = environment.now().timeIntervalSince(startTime)
            if elapsed < effectiveWindow {
                effectiveWindow = max(inputRateBucketInterval, elapsed)
            }
        }
        
        currentInputRatePerSecond = Double(totalEvents) / effectiveWindow
        currentIconTintColor = enableDynamicIconColor ? colorForRate(currentInputRatePerSecond) : nil
        notifyMenuBarUpdate()
    }

    private func colorForRate(_ ratePerSecond: Double) -> NSColor? {
        let apm = ratePerSecond * 60
        let thresholds = inputRateApmThresholds
        if apm < thresholds[1] { return nil }
        if apm >= thresholds[3] { return .systemRed }

        if apm <= thresholds[2] {
            let progress = (apm - thresholds[1]) / (thresholds[2] - thresholds[1])
            let lightGreen = lightenColor(.systemGreen, fraction: 0.6)
            return interpolateColor(from: lightGreen, to: .systemGreen, progress: progress)
        }

        let progress = (apm - thresholds[2]) / (thresholds[3] - thresholds[2])
        return interpolateColor(from: .systemYellow, to: .systemRed, progress: progress)
    }

    private func interpolateColor(from: NSColor, to: NSColor, progress: Double) -> NSColor {
        let fromColor = from.usingColorSpace(.deviceRGB) ?? from
        let toColor = to.usingColorSpace(.deviceRGB) ?? to
        var fr: CGFloat = 0
        var fg: CGFloat = 0
        var fb: CGFloat = 0
        var fa: CGFloat = 0
        var tr: CGFloat = 0
        var tg: CGFloat = 0
        var tb: CGFloat = 0
        var ta: CGFloat = 0
        fromColor.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        toColor.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        let t = CGFloat(max(0, min(1, progress)))
        return NSColor(
            red: fr + (tr - fr) * t,
            green: fg + (tg - fg) * t,
            blue: fb + (tb - fb) * t,
            alpha: fa + (ta - fa) * t
        )
    }

    private func lightenColor(_ color: NSColor, fraction: CGFloat) -> NSColor {
        let resolved = color.usingColorSpace(.deviceRGB) ?? color
        return resolved.blended(withFraction: min(max(fraction, 0), 1), of: .white) ?? resolved
    }

    // MARK: - 通知阈值

    private func updateNotificationBaselines() {
        updateKeyPressNotificationBaseline()
        updateClickNotificationBaseline()
    }

    private func updateKeyPressNotificationBaseline() {
        lastNotifiedKeyPresses = normalizedBaseline(currentStats.keyPresses, threshold: keyPressNotifyThreshold)
    }

    private func updateClickNotificationBaseline() {
        lastNotifiedClicks = normalizedBaseline(currentStats.totalClicks, threshold: clickNotifyThreshold)
    }

    private func normalizedBaseline(_ count: Int, threshold: Int) -> Int {
        guard threshold > 0 else { return 0 }
        return (count / threshold) * threshold
    }

    private func notifyKeyPressThresholdIfNeeded() {
        guard notificationsEnabled else { return }
        let threshold = keyPressNotifyThreshold
        guard threshold > 0 else { return }
        let count = currentStats.keyPresses
        guard count % threshold == 0 else { return }
        guard count != lastNotifiedKeyPresses else { return }
        lastNotifiedKeyPresses = count
        environment.sendThresholdNotification(.keyPresses, count, threshold)
    }

    private func notifyClickThresholdIfNeeded() {
        guard notificationsEnabled else { return }
        let threshold = clickNotifyThreshold
        guard threshold > 0 else { return }
        let count = currentStats.totalClicks
        guard count % threshold == 0 else { return }
        guard count != lastNotifiedClicks else { return }
        lastNotifiedClicks = count
        environment.sendThresholdNotification(.clicks, count, threshold)
    }
    
    // MARK: - 数据持久化
    
    private func saveStats() {
        guard ownsCaptureStore else { return }
        statsStateLock.lock()
        let statsSnapshot = currentStats
        let calendar = environment.calendar()
        let normalizedDate = calendar.startOfDay(for: statsSnapshot.date)
        let key = dateFormatter.string(from: normalizedDate)
        var normalizedStats = statsSnapshot
        normalizedStats.date = normalizedDate
        history[key] = normalizedStats
        let historySnapshot = (!batchesCaptureUpdates || historyNeedsSave) ? history : nil
        historyNeedsSave = false
        statsStateLock.unlock()

        if let encoded = try? JSONEncoder().encode(statsSnapshot) {
            userDefaults.set(encoded, forKey: statsKey)
        }
        if let historySnapshot, let encoded = try? JSONEncoder().encode(historySnapshot) {
            userDefaults.set(encoded, forKey: historyKey)
        }
    }

    func captureSnapshot(includingHistory: Bool) -> CaptureSnapshot {
        let rates = currentRatesSnapshot()
        statsStateLock.lock(); defer { statsStateLock.unlock() }
        return CaptureSnapshot(current: currentStats, history: includingHistory ? history : nil,
                               kps: rates.currentKPS, cps: rates.currentCPS,
                               sampledAt: ProcessInfo.processInfo.systemUptime,
                               calibrationFactor: mouseDistanceCalibrationFactor)
    }

    func receiveCaptureUpdate(_ snapshot: CaptureUpdate, historyPayload: HistoryPayload?) {
        guard !ownsCaptureStore else { return }
        statsStateLock.lock()
        if let historyPayload {
            captureHistoryPayload = historyPayload
            presentationHistory = nil
            recentAppHistory = nil
            globalHistory = nil
            chartHistory = nil
        }
        let menuCountsChanged = snapshot.current.keyPresses != currentStats.keyPresses
            || snapshot.current.totalClicks != currentStats.totalClicks
        if enableDynamicIconColor, menuBarUpdateHandler != nil,
           environment.calendar().isDate(snapshot.current.date, inSameDayAs: currentStats.date) {
            let keyDelta = snapshot.current.keyPresses - currentStats.keyPresses
            let clickDelta = snapshot.current.totalClicks - currentStats.totalClicks
            if keyDelta >= 0, clickDelta >= 0 {
                registerInputEvent(count: safeAdd(keyDelta, clickDelta))
            }
        }
        currentStats = snapshot.current
        receivedRates = (max(0, snapshot.kps), max(0, snapshot.cps), snapshot.sampledAt)
        cachedMouseDistanceCalibrationFactor = snapshot.calibrationFactor
        statsStateLock.unlock()
        if menuCountsChanged { notifyMenuBarUpdate() }
        notifyStatsUpdate()
    }

    /// Called from UI lifecycle callbacks. Keep the authoritative encoded snapshot
    /// so reopen, export, reset and import never fall back to older on-disk totals.
    func discardPresentationHistory() {
        guard !ownsCaptureStore else { return }
        statsStateLock.lock()
        presentationHistory = nil
        recentAppHistory = nil
        globalHistory = nil
        chartHistory = nil
        statsStateLock.unlock()
    }

    /// Call with statsStateLock held.
    private func readHistoryLocked() -> [String: DailyStats] {
        if ownsCaptureStore { return history }
        if let presentationHistory { return presentationHistory }
        let decoded = receivedHistory(DailyStats.self) ?? normalizedHistory(loadHistory(DailyStats.self))
        recentAppHistory = nil
        presentationHistory = decoded
        return decoded
    }

    /// Trends and activity calendars only need daily totals. Keep this projection
    /// separate so an export or a detail view always gets every breakdown.
    private func chartHistoryLocked() -> [String: DailyStats] {
        if ownsCaptureStore { return history }
        if let globalHistory { return globalHistory }
        if let chartHistory { return chartHistory }
        let days: [String: DailyStats]
        if let presentationHistory {
            days = presentationHistory.mapValues { day in
                var totals = day
                totals.keyPressCounts = [:]
                totals.appStats = [:]
                return totals
            }
        } else {
            let stored = receivedHistory(ChartDay.self) ?? loadHistory(ChartDay.self)
            days = stored.mapValues(\.totals)
        }
        let totals = normalizedHistory(days)
        chartHistory = totals
        return totals
    }

    private func receivedHistory<Day: Decodable>(_ type: Day.Type) -> [String: Day]? {
        guard let data = captureHistoryPayload?.data else { return nil }
        return try? JSONDecoder().decode(CaptureHistory<[String: Day]>.self, from: data).history
    }

    private func loadStats() -> DailyStats? {
        guard let data = userDefaults.data(forKey: statsKey),
              let stats = try? JSONDecoder().decode(DailyStats.self, from: data) else {
            return nil
        }
        return stats
    }

    private func loadHistory<Day: Decodable>(_ type: Day.Type) -> [String: Day] {
        guard let data = userDefaults.data(forKey: historyKey),
              let stored = try? JSONDecoder().decode([String: Day].self, from: data) else {
            return [:]
        }
        return stored
    }

    // MARK: - 数据导入导出

    fileprivate struct ExportPayload: Codable {
        let version: Int
        let scope: String?
        let exportedAt: Date
        let currentStats: DailyStats
        let history: [String: DailyStats]
    }

    /// A value snapshot: encoding can run off the main thread without reading
    /// live manager state or changing the export format.
    struct ExportSnapshot {
        fileprivate let payload: ExportPayload

        func encodedData() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(payload)
        }
    }

    struct PreparedImport {
        fileprivate let payload: ExportPayload

        func encodedData() throws -> Data { try ExportSnapshot(payload: payload).encodedData() }
    }

    private enum ImportError: LocalizedError {
        case invalidFormat
        case unsupportedVersion
        case emptyData

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return NSLocalizedString("import.error.invalidFormat", comment: "")
            case .unsupportedVersion:
                return NSLocalizedString("import.error.unsupportedVersion", comment: "")
            case .emptyData:
                return NSLocalizedString("import.error.emptyData", comment: "")
            }
        }
    }

    func exportStatsData() throws -> Data {
        try exportSnapshot().encodedData()
    }

    func exportSnapshot() -> ExportSnapshot {
        statsStateLock.lock()
        var exportHistory = readHistoryLocked()
        var current = currentStats
        statsStateLock.unlock()
        let normalizedDate = environment.calendar().startOfDay(for: current.date)
        current.date = normalizedDate
        let key = dateFormatter.string(from: normalizedDate)
        exportHistory[key] = current

        let payload = ExportPayload(
            version: 1,
            scope: "currentDevice",
            exportedAt: environment.now(),
            currentStats: current,
            history: exportHistory
        )
        return ExportSnapshot(payload: payload)
    }

    func importStatsData(from data: Data, mode: ImportMode = .overwrite) throws {
        applyPreparedImport(try Self.prepareStatsImport(from: data), mode: mode)
    }

    /// Decoding has no manager or storage side effects. The UI may prepare a
    /// large file on its I/O queue, then commit through the existing main-thread
    /// timer, normalization and persistence path.
    static func prepareStatsImport(from data: Data) throws -> PreparedImport {
        guard !data.isEmpty else { throw ImportError.emptyData }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let payload: ExportPayload
        do {
            payload = try decoder.decode(ExportPayload.self, from: data)
        } catch {
            throw ImportError.invalidFormat
        }

        guard payload.version == 1 else { throw ImportError.unsupportedVersion }

        return PreparedImport(payload: payload)
    }

    func applyPreparedImport(_ prepared: PreparedImport, mode: ImportMode = .overwrite) {
        guard ownsCaptureStore else { return }
        applyImportedPayload(prepared.payload, mode: mode)
    }

    private func applyImportedPayload(_ payload: ExportPayload, mode: ImportMode) {
        saveTimer?.invalidate()
        saveTimer = nil

        var importedHistory = normalizedHistory(payload.history)
        let importedCurrent = normalizedDailyStats(payload.currentStats)
        importedHistory[dateFormatter.string(from: importedCurrent.date)] = importedCurrent

        let today = environment.calendar().startOfDay(for: environment.now())
        let todayKey = dateFormatter.string(from: today)
        // Keep the live base and replacement in one transaction. XPC input
        // arriving during a merge must not be overwritten by an older snapshot.
        statsStateLock.lock()
        let resolvedHistory: [String: DailyStats]
        switch mode {
        case .overwrite:
            resolvedHistory = importedHistory
        case .merge:
            var base = normalizedHistory(history)
            let current = normalizedDailyStats(currentStats)
            base[dateFormatter.string(from: current.date)] = current
            resolvedHistory = mergedHistory(base: base, imported: importedHistory)
        }

        history = resolvedHistory
        historyNeedsSave = true
        currentStats = resolvedHistory[todayKey] ?? DailyStats(date: today)
        recentKeyTimestamps.removeAll()
        recentClickTimestamps.removeAll()
        keyTimestampsHead = 0
        clickTimestampsHead = 0
        statsStateLock.unlock()

        saveTimer?.invalidate()
        saveTimer = nil
        updateNotificationBaselines()
        saveStats()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
    }

    private func currentHistorySnapshot() -> [String: DailyStats] {
        statsStateLock.lock()
        let historySnap = history
        let current = currentStats
        statsStateLock.unlock()
        var snapshot = normalizedHistory(historySnap)
        let normalizedCurrent = normalizedDailyStats(current)
        snapshot[dateFormatter.string(from: normalizedCurrent.date)] = normalizedCurrent
        return snapshot
    }

    private func mergedHistory(base: [String: DailyStats], imported: [String: DailyStats]) -> [String: DailyStats] {
        var merged = base

        for (dayKey, importedStats) in imported {
            if let existingStats = merged[dayKey] {
                merged[dayKey] = mergedDailyStats(existingStats, importedStats)
            } else {
                merged[dayKey] = importedStats
            }
        }

        return merged
    }

    private func mergedDailyStats(_ lhs: DailyStats, _ rhs: DailyStats) -> DailyStats {
        var merged = DailyStats(date: lhs.date)
        merged.keyPresses = safeAdd(lhs.keyPresses, rhs.keyPresses)
        merged.leftClicks = safeAdd(lhs.leftClicks, rhs.leftClicks)
        merged.rightClicks = safeAdd(lhs.rightClicks, rhs.rightClicks)
        merged.middleClicks = safeAdd(lhs.middleClicks, rhs.middleClicks)
        merged.sideBackClicks = safeAdd(lhs.sideBackClicks, rhs.sideBackClicks)
        merged.sideForwardClicks = safeAdd(lhs.sideForwardClicks, rhs.sideForwardClicks)
        merged.mouseDistance = safeAddDistance(lhs.mouseDistance, rhs.mouseDistance)
        merged.scrollDistance = safeAddDistance(lhs.scrollDistance, rhs.scrollDistance)
        merged.scrollSessions = aggregateScrollSessionCounts([lhs.scrollSessions, rhs.scrollSessions])
        merged.peakKPS = max(lhs.peakKPS, rhs.peakKPS)
        merged.peakCPS = max(lhs.peakCPS, rhs.peakCPS)
        merged.keyPressCounts = mergedCounterMap(lhs.keyPressCounts, rhs.keyPressCounts)
        merged.appStats = mergedAppStats(lhs.appStats, rhs.appStats)
        return merged
    }

    private func mergedCounterMap(_ lhs: [String: Int], _ rhs: [String: Int]) -> [String: Int] {
        var merged = normalizedKeyPressCounts(lhs)
        addKeyPressCounts(rhs, to: &merged)
        return merged
    }

    private func normalizedKeyPressCounts(_ counts: [String: Int]) -> [String: Int] {
        var normalized: [String: Int] = [:]
        addKeyPressCounts(counts, to: &normalized)
        return normalized
    }

    private func addKeyPressCounts(_ counts: [String: Int], to totals: inout [String: Int]) {
        for (key, count) in counts where count > 0 {
            let name = canonicalKeyName(key)
            guard !name.isEmpty else { continue }
            totals[name] = safeAdd(totals[name] ?? 0, count)
        }
    }

    private func mergedAppStats(_ lhs: [String: AppStats], _ rhs: [String: AppStats]) -> [String: AppStats] {
        var merged = lhs

        for (bundleId, importedStats) in rhs {
            if var existing = merged[bundleId] {
                existing.bundleId = bundleId
                existing.keyPresses = safeAdd(existing.keyPresses, importedStats.keyPresses)
                existing.keyPressCounts = mergedCounterMap(existing.keyPressCounts, importedStats.keyPressCounts)
                existing.leftClicks = safeAdd(existing.leftClicks, importedStats.leftClicks)
                existing.rightClicks = safeAdd(existing.rightClicks, importedStats.rightClicks)
                existing.middleClicks = safeAdd(existing.middleClicks, importedStats.middleClicks)
                existing.sideBackClicks = safeAdd(existing.sideBackClicks, importedStats.sideBackClicks)
                existing.sideForwardClicks = safeAdd(existing.sideForwardClicks, importedStats.sideForwardClicks)
                existing.scrollDistance = safeAddDistance(existing.scrollDistance, importedStats.scrollDistance)
                existing.scrollSessions = aggregateScrollSessionCounts([
                    existing.scrollSessions,
                    importedStats.scrollSessions
                ])

                let importedName = importedStats.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !importedName.isEmpty {
                    existing.displayName = importedName
                }

                merged[bundleId] = existing
            } else {
                merged[bundleId] = importedStats
            }
        }

        return merged
    }

    private func safeAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private func safeAddDistance(_ lhs: Double, _ rhs: Double) -> Double {
        let sum = lhs + rhs
        return sum.isFinite ? max(0, sum) : Double.greatestFiniteMagnitude
    }

    private func normalizedHistory(_ importedHistory: [String: DailyStats]) -> [String: DailyStats] {
        var normalized: [String: DailyStats] = [:]
        for (originalKey, stats) in importedHistory.sorted(by: { $0.key < $1.key }) {
            var daily = normalizedDailyStats(stats)
            if let keyDate = dateFormatter.date(from: originalKey),
               dateFormatter.string(from: keyDate) == originalKey {
                daily.date = environment.calendar().startOfDay(for: keyDate)
                normalized[originalKey] = daily
                continue
            }

            let fallbackKey = dateFormatter.string(from: daily.date)
            if normalized[fallbackKey] == nil {
                normalized[fallbackKey] = daily
            }
        }
        return normalized
    }

    private func normalizedDailyStats(_ stats: DailyStats) -> DailyStats {
        var normalized = stats
        normalized.date = environment.calendar().startOfDay(for: normalized.date)
        normalized.keyPresses = max(0, normalized.keyPresses)
        normalized.leftClicks = max(0, normalized.leftClicks)
        normalized.rightClicks = max(0, normalized.rightClicks)
        normalized.middleClicks = max(0, normalized.middleClicks)
        normalized.sideBackClicks = max(0, normalized.sideBackClicks)
        normalized.sideForwardClicks = max(0, normalized.sideForwardClicks)
        normalized.mouseDistance = normalized.mouseDistance.isFinite ? max(0, normalized.mouseDistance) : 0
        normalized.scrollDistance = normalized.scrollDistance.isFinite ? max(0, normalized.scrollDistance) : 0
        normalized.scrollSessions = max(0, normalized.scrollSessions)
        normalized.peakKPS = max(0, normalized.peakKPS)
        normalized.peakCPS = max(0, normalized.peakCPS)
        normalized.keyPressCounts = normalizedKeyPressCounts(normalized.keyPressCounts)
        normalized.appStats = normalizedAppStats(normalized.appStats)
        return normalized
    }

    private func normalizedAppStats(_ appStats: [String: AppStats]) -> [String: AppStats] {
        var normalized: [String: AppStats] = [:]

        for (rawBundleId, value) in appStats {
            let bundleId = value.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackBundleId = rawBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedBundleId = bundleId.isEmpty ? fallbackBundleId : bundleId
            guard !resolvedBundleId.isEmpty else { continue }

            var stats = value
            stats.bundleId = resolvedBundleId
            stats.keyPresses = max(0, stats.keyPresses)
            stats.keyPressCounts = normalizedKeyPressCounts(stats.keyPressCounts)
            stats.leftClicks = max(0, stats.leftClicks)
            stats.rightClicks = max(0, stats.rightClicks)
            stats.middleClicks = max(0, stats.middleClicks)
            stats.sideBackClicks = max(0, stats.sideBackClicks)
            stats.sideForwardClicks = max(0, stats.sideForwardClicks)
            stats.scrollDistance = stats.scrollDistance.isFinite ? max(0, stats.scrollDistance) : 0
            stats.scrollSessions = max(0, stats.scrollSessions)
            normalized[resolvedBundleId] = stats
        }

        return normalized
    }

    private func scheduleSave() {
        guard ownsCaptureStore, environment.schedulesAutomaticWork else { return }
        let schedule = { [weak self] in
            guard let self = self, self.saveTimer == nil else { return }
            self.saveTimer = Timer.scheduledTimer(withTimeInterval: self.saveInterval, repeats: false) { [weak self] _ in
                self?.saveTimer = nil
                self?.saveStats()
            }
        }
        if Thread.isMainThread {
            schedule()
        } else {
            DispatchQueue.main.async(execute: schedule)
        }
    }

    @discardableResult
    func addStatsUpdateHandler(_ handler: @escaping () -> Void) -> UUID {
        precondition(Thread.isMainThread)
        let token = UUID()
        statsUpdateHandlers[token] = handler
        return token
    }

    func removeStatsUpdateHandler(_ token: UUID) {
        precondition(Thread.isMainThread)
        statsUpdateHandlers[token] = nil
    }

    private func notifyMenuBarUpdate() {
        menuBarPresentationLock.lock()
        guard menuBarHandler != nil, !menuBarUpdateQueued else {
            menuBarPresentationLock.unlock()
            return
        }
        menuBarUpdateQueued = true
        menuBarPresentationLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.menuBarPresentationLock.lock()
            self.menuBarUpdateQueued = false
            let handler = self.menuBarHandler
            self.menuBarPresentationLock.unlock()
            handler?()
        }
    }

    private func notifyStatsUpdate() {
        if batchesCaptureUpdates {
            scheduleDebouncedStatsUpdate()
            return
        }
        deliverStatsUpdate()
    }

    private func deliverStatsUpdate() {
        if Thread.isMainThread && statsUpdateHandlers.isEmpty { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for handler in Array(self.statsUpdateHandlers.values) {
                handler()
            }
        }
    }

    private func scheduleDebouncedStatsUpdate() {
        guard environment.schedulesAutomaticWork else { return }
        let schedule = { [weak self] in
            guard let self, !self.statsUpdateHandlers.isEmpty, self.statsUpdateTimer == nil else { return }
            // A bounded one-shot refresh keeps its original deadline while
            // movement/scrolling continues; new samples share the same timer.
            self.statsUpdateTimer = Timer.scheduledTimer(withTimeInterval: self.statsUpdateDebounceInterval, repeats: false) { [weak self] _ in
                self?.statsUpdateTimer = nil
                self?.deliverStatsUpdate()
            }
            if let timer = self.statsUpdateTimer { RunLoop.main.add(timer, forMode: .common) }
        }
        if Thread.isMainThread { schedule() }
        else { DispatchQueue.main.async(execute: schedule) }
    }

    func persistCaptureState() {
        guard saveTimer != nil else { return }
        saveTimer?.invalidate(); saveTimer = nil
        saveStats()
    }

    func flushPendingSave() {
        saveTimer?.invalidate()
        saveTimer = nil
        statsUpdateTimer?.invalidate()
        statsUpdateTimer = nil
        midnightCheckTimer?.invalidate()
        midnightCheckTimer = nil
        inputRateTimer?.invalidate()
        inputRateTimer = nil
        saveStats()
    }
    
    // MARK: - 午夜重置

    private func setupMidnightReset() {
        guard environment.schedulesAutomaticWork else { return }
        scheduleNextMidnightReset()
    }

    private func scheduleNextMidnightReset() {
        guard environment.schedulesAutomaticWork else { return }
        let doSchedule = { [weak self] in
            guard let self = self else { return }
            self.midnightCheckTimer?.invalidate()

            // 使用日历计算下一次午夜，避免睡眠/时区变化导致的漂移
            let calendar = self.environment.calendar()
            let now = self.environment.now()
            guard let nextMidnight = calendar.nextDate(
                after: now,
                matching: DateComponents(hour: 0, minute: 0, second: 0),
                matchingPolicy: .nextTime
            ) else {
                print("⚠️ 无法计算午夜时间")
                return
            }

            let timeToMidnight = nextMidnight.timeIntervalSince(now)
            print("📅 设置午夜重置：将在 \(Int(timeToMidnight)) 秒后（\(nextMidnight)）执行重置")

            self.midnightCheckTimer = Timer.scheduledTimer(withTimeInterval: timeToMidnight, repeats: false) { [weak self] _ in
                self?.performMidnightReset()
            }

            // 确保 timer 在所有 RunLoop 模式下都能运行
            if let timer = self.midnightCheckTimer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        if Thread.isMainThread {
            doSchedule()
        } else {
            DispatchQueue.main.async(execute: doSchedule)
        }
    }

    private func performMidnightReset() {
        let now = environment.now()
        print("🌙 午夜重置触发：\(now)")

        var didReset = false
        statsStateLock.lock()
        if !environment.calendar().isDate(currentStats.date, inSameDayAs: now) {
            resetStatsLocked(for: now)
            didReset = true
        }
        statsStateLock.unlock()

        if didReset {
            updateNotificationBaselines()
            notifyMenuBarUpdate()
            notifyStatsUpdate()
        }

        scheduleNextMidnightReset()
    }
    
    func resetStats() {
        guard ownsCaptureStore else { return }
        statsStateLock.lock()
        resetStatsLocked(for: environment.now())
        statsStateLock.unlock()
        updateNotificationBaselines()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
    }

    /// 调用前必须持有 statsStateLock
    private func ensureCurrentDayLocked() {
        let now = environment.now()
        if !environment.calendar().isDate(currentStats.date, inSameDayAs: now) {
            resetStatsLocked(for: now)
        }
    }

    private func resetStats(for date: Date) {
        statsStateLock.lock()
        resetStatsLocked(for: date)
        statsStateLock.unlock()
        updateNotificationBaselines()
        notifyMenuBarUpdate()
        notifyStatsUpdate()
    }

    /// 调用前必须持有 statsStateLock — 原子重置 currentStats 和滑动窗口
    private func resetStatsLocked(for date: Date) {
        let calendar = environment.calendar()
        if !calendar.isDate(currentStats.date, inSameDayAs: date) {
            var previousDaySnapshot = currentStats
            previousDaySnapshot.date = calendar.startOfDay(for: previousDaySnapshot.date)
            history[dateFormatter.string(from: previousDaySnapshot.date)] = previousDaySnapshot
            historyNeedsSave = true
        }
        currentStats = DailyStats(date: date)
        recentKeyTimestamps.removeAll()
        recentClickTimestamps.removeAll()
        keyTimestampsHead = 0
        clickTimestampsHead = 0
    }
    
    // MARK: - 格式化显示
    
    /// 获取菜单栏显示的简短文本
    func getMenuBarText() -> String {
        let parts = getMenuBarTextParts()
        return "\(parts.keys) \(parts.clicks)"
    }

    /// 获取菜单栏显示的数字部分
    func getMenuBarTextParts() -> (keys: String, clicks: String) {
        let stats = displayCurrentStats()
        let keys = showKeyPressesInMenuBar ? formatMenuBarNumber(stats.keyPresses) : ""
        let clicks = showMouseClicksInMenuBar ? formatMenuBarNumber(stats.totalClicks) : ""
        return (keys, clicks)
    }
    
    /// 菜单栏紧凑显示（最多三位有效数字）
    private func formatMenuBarNumber(_ number: Int) -> String {
        return formatMenuBarCompactNumber(number)
    }

    /// 通用紧凑显示
    private func formatNumber(_ number: Int) -> String {
        if number >= 1000000 {
            return String(format: "%.1fM", Double(number) / 1000000)
        } else if number >= 1000 {
            return String(format: "%.1fk", Double(number) / 1000)
        } else {
            return "\(number)"
        }
    }

    /// 按次数排序的键位统计
    func keyPressBreakdownSorted() -> [(key: String, count: Int)] {
        return keyBreakdownDisplayCounts(from: displayCurrentStats().keyPressCounts)
            .sorted {
                if $0.value != $1.value {
                    return $0.value > $1.value
                }
                return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
            .map { (key: $0.key, count: $0.value) }
    }
}

// MARK: - 历史数据

extension StatsManager {
    struct KeyboardHeatmapDay {
        let date: Date
        let totalKeyPresses: Int
        let keyCounts: [String: Int]

        var maxCount: Int {
            keyCounts.values.max() ?? 0
        }
    }

    enum HistoryRange {
        case today
        case yesterday
        case week
        case month
    }
    
    enum HistoryMetric {
        case keyPresses
        case clicks
        case mouseDistance
        case scrollDistance
    }

    typealias HistoryPoint = (date: Date, value: Double)

    struct HistoryTrendSeries {
        let display: [HistoryPoint]
    }

    /// 键盘热力图可切换日期边界（按天连续切换）
    /// 起始日取「首次出现键盘数据」与今天之间的最早日期；若没有任何键盘数据则今天=起始日。
    func keyboardHeatmapDateBounds() -> (start: Date, end: Date) {
        assert(Thread.isMainThread)
        let calendar = environment.calendar()
        let today = calendar.startOfDay(for: environment.now())

        var earliestDate: Date?

        for daily in displayHistorySnapshot().values {
            guard daily.keyPresses > 0 || !daily.keyPressCounts.isEmpty else { continue }
            let date = calendar.startOfDay(for: daily.date)
            if date > today { continue }
            if let existing = earliestDate {
                if date < existing {
                    earliestDate = date
                }
            } else {
                earliestDate = date
            }
        }

        let start = earliestDate ?? today
        return (start: min(start, today), end: today)
    }

    /// 按天获取键盘热力图数据。
    /// 组合键（如 Cmd+A）会拆分并分别累加到各个按键：Cmd +1、A +1。
    func keyboardHeatmapDay(for date: Date) -> KeyboardHeatmapDay {
        assert(Thread.isMainThread)
        let normalizedDate = environment.calendar().startOfDay(for: date)
        let dayKey = dateFormatter.string(from: normalizedDate)
        let daily = displayHistorySnapshot()[dayKey] ?? DailyStats(date: normalizedDate)
        let aggregated = keyboardHeatmapCounts(from: daily.keyPressCounts)
        return KeyboardHeatmapDay(
            date: normalizedDate,
            totalKeyPresses: max(0, daily.keyPresses),
            keyCounts: aggregated
        )
    }
    
    func historySeries(range: HistoryRange, metric: HistoryMetric) -> [HistoryPoint] {
        historyTrendSeries(range: range, metric: metric).display
    }

    func historyTrendSeries(range: HistoryRange, metric: HistoryMetric) -> HistoryTrendSeries {
        let dates = datesInRange(range)
        let calendar = environment.calendar()
        statsStateLock.lock()
        let current = currentStats
        let needsArchive = dates.contains { !calendar.isDate($0, inSameDayAs: current.date) }
        let history = needsArchive ? chartHistoryLocked() : [:]
        statsStateLock.unlock()
        // These charts read scalar metrics from a short date range. The store
        // already normalizes date keys, and the current day overrides its saved copy.
        let points = dates.map { date -> HistoryPoint in
            let key = dateFormatter.string(from: date)
            let stats = calendar.isDate(date, inSameDayAs: current.date)
                ? current : (history[key] ?? DailyStats(date: date))
            return (date, metricValue(metric, for: stats))
        }
        return HistoryTrendSeries(display: points)
    }
    
    func formatHistoryValue(metric: HistoryMetric, value: Double) -> String {
        switch metric {
        case .keyPresses, .clicks:
            let count: Int
            if !value.isFinite || value <= 0 { count = 0 }
            else if value >= Double(Int.max) { count = Int.max }
            else { count = Int(value) }
            return formatNumber(count)
        case .mouseDistance:
            return formatMouseDistance(value)
        case .scrollDistance:
            return formatScrollDistance(value)
        }
    }

    // MARK: - 热力图数据

    /// 返回从本周周起始日往前推 52 周，到今天为止的数据数组（不包含未来日期）
    /// 缺失日期填充为 0
    func heatmapActivityData() -> [(date: Date, keyPresses: Int, clicks: Int)] {
        assert(Thread.isMainThread)
        let calendar = environment.calendar()
        let today = calendar.startOfDay(for: environment.now())

        // 计算本周周起始日
        let todayWeekday = calendar.component(.weekday, from: today)
        let daysFromWeekStart = (todayWeekday - calendar.firstWeekday + 7) % 7
        guard let weekStart = calendar.date(byAdding: .day, value: -daysFromWeekStart, to: today) else {
            return []
        }

        // 向前推 52 周，当前周作为第 53 列（不包含未来日期）
        let totalWeeks = 53
        let startOffsetDays = (totalWeeks - 1) * 7
        guard let startDate = calendar.date(byAdding: .day, value: -startOffsetDays, to: weekStart) else {
            return []
        }

        var result: [(date: Date, keyPresses: Int, clicks: Int)] = []
        var current = startDate
        statsStateLock.lock()
        let displayHistory = chartHistoryLocked()
        let live = currentStats
        statsStateLock.unlock()
        let liveKey = dateFormatter.string(from: calendar.startOfDay(for: live.date))

        while current <= today {
            let key = dateFormatter.string(from: current)

            if let stats = key == liveKey ? live : displayHistory[key] {
                result.append((current, max(0, stats.keyPresses), stats.totalClicks))
            } else {
                result.append((current, 0, 0))
            }

            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else {
                assertionFailure("Failed to advance date when building heatmap data.")
                break
            }
            current = next
        }

        return result
    }
    
    private func datesInRange(_ range: HistoryRange) -> [Date] {
        let calendar = environment.calendar()
        let today = calendar.startOfDay(for: environment.now())
        
        let startDate: Date
        switch range {
        case .today:
            startDate = today
        case .yesterday:
            startDate = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        case .week:
            startDate = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month:
            startDate = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        }
        
        var dates: [Date] = []
        var date = startDate
        while date <= today {
            dates.append(date)
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        if dates.isEmpty {
            dates = [today]
        }
        return dates
    }
    
    private func metricValue(_ metric: HistoryMetric, for stats: DailyStats) -> Double {
        switch metric {
        case .keyPresses:
            return Double(max(0, stats.keyPresses))
        case .clicks:
            return Double(stats.totalClicks)
        case .mouseDistance:
            return stats.mouseDistance.isFinite ? max(0, stats.mouseDistance) : 0
        case .scrollDistance:
            return stats.scrollDistance.isFinite ? max(0, stats.scrollDistance) : 0
        }
    }
    
    func formatMouseDistance(_ distance: Double) -> String {
        let meters = distance * mouseDistanceMetersPerPixel
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000)
        } else if distance >= 1000 {
            return String(format: "%.1f m", meters)
        }
        return String(format: "%.0f px", distance)
    }
    
    private func formatScrollDistance(_ distance: Double) -> String {
        if distance >= 1_000_000 {
            return String(format: "%.1f MPx", distance / 1_000_000)
        } else if distance >= 1000 {
            return String(format: "%.1f kPx", distance / 1000)
        } else {
            return String(format: "%.0f Px", distance)
        }
    }
    
    // MARK: - 全量统计
    
    func getAllTimeStats() -> AllTimeStats {
        allTimeStats(in: displayHistorySnapshot())
    }

    func allTimeActivity() -> (stats: AllTimeStats, days: [(date: Date, keyPresses: Int, clicks: Int)]) {
        let history = displayHistorySnapshot()
        return (allTimeStats(in: history), history.values.map { ($0.date, $0.keyPresses, $0.totalClicks) })
    }

    private func allTimeStats(in history: [String: DailyStats]) -> AllTimeStats {
        var totalStats = AllTimeStats.initial()
        var weekdayStats: [Int: (total: Int, count: Int)] = [:]
        for daily in history.values {
            aggregate(daily: daily, into: &totalStats, weekdays: &weekdayStats)
        }

        var maxAvg = 0.0
        var bestWeekday: Int?
        for (day, data) in weekdayStats {
            guard data.count > 0 else { continue }
            let avg = Double(data.total) / Double(data.count)
            if avg > maxAvg {
                maxAvg = avg
                bestWeekday = day
            }
        }
        totalStats.mostActiveWeekday = bestWeekday

        return totalStats
    }

    /// Uses the same global display history as Heatmap/All-Time, including current
    /// unsaved data and configured remote shards. Normalization reuses historical key identity.
    /// Derived on demand: no save, cache, scheduling or persistence.
    func keyboardDailyUsage() -> [KeyboardUsageDay] {
        assert(Thread.isMainThread)
        return displayHistorySnapshot().map { key, day in
            KeyboardUsageDay(dayKey: key, totalKeyPresses: day.keyPresses, keyPressCounts: day.keyPressCounts)
        }.sorted { $0.dayKey < $1.dayKey }
    }

    func cumulativeKeyboardTimeline() -> [CumulativeKeyboardSnapshot] {
        assert(Thread.isMainThread)
        return CumulativeKeyboardTimeline.build(history: displayHistorySnapshot())
    }

    func cumulativeKeyboardSnapshot(asOf date: Date) -> CumulativeKeyboardSnapshot? {
        assert(Thread.isMainThread)
        return CumulativeKeyboardTimeline.snapshot(
            asOf: dateFormatter.string(from: environment.calendar().startOfDay(for: date)),
            history: displayHistorySnapshot()
        )
    }

    /// Shares normalized global display history with cumulative keyboard snapshots.
    func keyboardTrackingPeriod() -> KeyboardTrackingPeriod? {
        assert(Thread.isMainThread)
        return KeyboardTrackingPeriod(
            history: displayHistorySnapshot(),
            calendar: environment.calendar(),
            dateKeyFormatter: dateFormatter
        )
    }

    /// One normalized display snapshot supplies every Growth projection coherently.
    func growthKeyboardPresentation(now: Date, calendar: Calendar) -> GrowthKeyboardPresentation? {
        assert(Thread.isMainThread)
        let snapshot = displayHistorySnapshot()
        guard let period = KeyboardTrackingPeriod(history: snapshot,
            calendar: environment.calendar(), dateKeyFormatter: dateFormatter) else { return nil }
        let daily = snapshot.map { key, day in
            KeyboardUsageDay(dayKey: key, totalKeyPresses: day.keyPresses, keyPressCounts: day.keyPressCounts)
        }.sorted { $0.dayKey < $1.dayKey }
        return GrowthKeyboardPresentation(timeline: CumulativeKeyboardTimeline.build(history: snapshot),
            period: period, now: now, calendar: calendar, dailyUsage: daily)
    }

    /// Returns normalized local history, including the unsaved current day exactly once.
    func localHistorySnapshot() -> [String: DailyStats] {
        statsStateLock.lock()
        var snapshot = readHistoryLocked()
        let current = currentStats
        statsStateLock.unlock()
        let normalized = normalizedDailyStats(current)
        snapshot[dateFormatter.string(from: normalized.date)] = normalized
        return normalizedHistory(snapshot)
    }

    func displayCurrentStats() -> DailyStats {
        statsStateLock.lock()
        defer { statsStateLock.unlock() }
        return currentStats
    }

    /// Global keyboard and activity pages share normalized days. Full per-app
    /// detail remains independently available for the app browser and exports.
    private func displayHistorySnapshot() -> [String: DailyStats] {
        if ownsCaptureStore { return localHistorySnapshot() }
        statsStateLock.lock()
        var snapshot: [String: DailyStats]
        if let globalHistory {
            snapshot = globalHistory
        } else {
            let days = receivedHistory(GlobalDay.self) ?? loadHistory(GlobalDay.self)
            snapshot = normalizedHistory(days.mapValues(\.stats))
            globalHistory = snapshot
            chartHistory = nil
        }
        var current = currentStats
        statsStateLock.unlock()
        if current.hasActivityTotals { current.appStats = [:] }
        current = normalizedDailyStats(current)
        snapshot[dateFormatter.string(from: current.date)] = current
        return snapshot
    }
    
    private func aggregate(daily: DailyStats, into total: inout AllTimeStats, weekdays: inout [Int: (total: Int, count: Int)]) {
        guard daily.hasAnyActivity else { return }
        total.totalKeyPresses = safeAdd(total.totalKeyPresses, daily.keyPresses)
        total.totalLeftClicks = safeAdd(total.totalLeftClicks, daily.leftClicks)
        total.totalRightClicks = safeAdd(total.totalRightClicks, daily.rightClicks)
        total.totalMiddleClicks = safeAdd(total.totalMiddleClicks, daily.middleClicks)
        total.totalSideBackClicks = safeAdd(total.totalSideBackClicks, daily.sideBackClicks)
        total.totalSideForwardClicks = safeAdd(total.totalSideForwardClicks, daily.sideForwardClicks)
        total.totalMouseDistance = safeAddDistance(total.totalMouseDistance, daily.mouseDistance)
        total.totalScrollDistance = safeAddDistance(total.totalScrollDistance, daily.scrollDistance)
        total.totalScrollSessions = aggregateScrollSessionCounts([
            total.totalScrollSessions,
            daily.scrollSessions
        ])

        for (key, count) in daily.keyPressCounts {
            total.keyPressCounts[key] = safeAdd(total.keyPressCounts[key] ?? 0, count)
        }

        if daily.keyPresses > total.maxDailyKeyPresses {
            total.maxDailyKeyPresses = daily.keyPresses
            total.maxDailyKeyPressesDate = daily.date
        }
        let dailyClicks = daily.totalClicks
        if dailyClicks > total.maxDailyClicks {
            total.maxDailyClicks = dailyClicks
            total.maxDailyClicksDate = daily.date
        }
        if daily.keyPresses > 0 {
            total.keyActiveDays += 1
        }
        if dailyClicks > 0 {
            total.clickActiveDays += 1
        }

        let calendar = environment.calendar()
        let date = calendar.startOfDay(for: daily.date)
        
        // Weekday stats
        let weekday = calendar.component(.weekday, from: date)
        let dailyTotal = safeAdd(daily.keyPresses, dailyClicks)
        let current = weekdays[weekday, default: (0, 0)]
        let increment = dailyTotal > 0 ? 1 : 0
        weekdays[weekday] = (safeAdd(current.total, dailyTotal), safeAdd(current.count, increment))
        
        if let currentFirst = total.firstDate {
            if date < currentFirst {
                total.firstDate = date
            }
        } else {
            total.firstDate = date
        }
        if let currentLast = total.lastDate {
            if date > currentLast {
                total.lastDate = date
            }
        } else {
            total.lastDate = date
        }
        total.activeDays += 1
    }
}

// MARK: - 按应用统计

extension StatsManager {
    enum AppStatsRange {
        case today
        case week
        case month
        case all
    }

    func appStatsSummary(range: AppStatsRange) -> [AppStats] {
        var totals: [String: AppStats] = [:]
        for daily in appStatsDays(in: range) {
            mergeAppStats(from: daily, into: &totals)
        }
        return Array(totals.values)
    }

    /// Derived on demand; shares the existing App Stats range and writes nothing.
    func interactionProfiles(range: AppStatsRange) -> [InteractionProfile] {
        InteractionProfileCalculator.calculate(days: appStatsDays(in: range))
    }

    private func appStatsDays(in range: AppStatsRange) -> [DailyStats] {
        if range == .today { return [displayCurrentStats()] }
        let dates = range == .all ? [] : appStatsDates(in: range)
        let keys = dates.map(dateFormatter.string(from:))
        statsStateLock.lock()
        let current = currentStats
        let currentKey = dateFormatter.string(from: current.date)
        let days = range == .all ? readHistoryLocked() : recentAppDaysLocked(for: Set(keys).subtracting([currentKey]))
        statsStateLock.unlock()

        if range == .all {
            return days.values.filter { dateFormatter.string(from: $0.date) != currentKey } + [current]
        }
        return zip(keys, dates).map { key, date in
            key == currentKey ? current : (days[key] ?? DailyStats(date: date))
        }
    }

    private func recentAppDaysLocked(for keys: Set<String>) -> [String: DailyStats] {
        if ownsCaptureStore { return history }
        if let presentationHistory { return presentationHistory }
        if let recentAppHistory, keys.isSubset(of: recentAppHistory.keys) { return recentAppHistory.days }
        let calendar = environment.calendar()
        func selected(_ data: Data, envelope: Bool) -> [String: DailyStats]? {
            SelectedDays.read(from: data, envelope: envelope, keys: keys, formatter: dateFormatter, calendar: calendar)
        }
        let decoded = captureHistoryPayload?.data.flatMap { selected($0, envelope: true) }
            ?? userDefaults.data(forKey: historyKey).flatMap { selected($0, envelope: false) }
            ?? [:]
        let days = normalizedHistory(decoded)
        recentAppHistory = (keys, days)
        return days
    }

    private func appStatsDates(in range: AppStatsRange) -> [Date] {
        let calendar = environment.calendar()
        let today = calendar.startOfDay(for: environment.now())

        let startDate: Date
        switch range {
        case .today:
            startDate = today
        case .week:
            startDate = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month:
            startDate = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .all:
            startDate = today
        }

        var dates: [Date] = []
        var date = startDate
        while date <= today {
            dates.append(date)
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        if dates.isEmpty {
            dates = [today]
        }
        return dates
    }

    private func mergeAppStats(from daily: DailyStats, into totals: inout [String: AppStats]) {
        guard !daily.appStats.isEmpty else { return }
        for (bundleId, appStats) in daily.appStats {
            accumulate(appStats, into: &totals[bundleId, default: AppStats(bundleId: bundleId, displayName: appStats.displayName)])
        }
    }

    private func accumulate(_ appStats: AppStats, into total: inout AppStats) {
        if !appStats.displayName.isEmpty {
            total.displayName = appStats.displayName
        }
        total.keyPresses = safeAdd(total.keyPresses, appStats.keyPresses)
        addKeyPressCounts(appStats.keyPressCounts, to: &total.keyPressCounts)
        total.leftClicks = safeAdd(total.leftClicks, appStats.leftClicks)
        total.rightClicks = safeAdd(total.rightClicks, appStats.rightClicks)
        total.middleClicks = safeAdd(total.middleClicks, appStats.middleClicks)
        total.sideBackClicks = safeAdd(total.sideBackClicks, appStats.sideBackClicks)
        total.sideForwardClicks = safeAdd(total.sideForwardClicks, appStats.sideForwardClicks)
        total.scrollDistance = safeAddDistance(total.scrollDistance, appStats.scrollDistance)
        total.scrollSessions = aggregateScrollSessionCounts([
            total.scrollSessions,
            appStats.scrollSessions
        ])
    }
}
