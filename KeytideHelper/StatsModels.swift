import Foundation
import CoreGraphics

let baseMetersPerPixel: Double = 0.000264583

/// Formats menu bar counters with up to three significant digits.
func formatMenuBarCompactNumber(_ number: Int) -> String {
    guard number >= 1_000 else { return "\(number)" }

    let units = ["k", "M", "B", "T", "P", "E"]
    var divisor = 1_000.0
    var unitIndex = 0

    while unitIndex < units.count - 1 && Double(number) / divisor >= 1_000 {
        divisor *= 1_000
        unitIndex += 1
    }

    let value = Double(number) / divisor
    let integerDigits = max(1, Int(log10(value)) + 1)
    let decimalPlaces = max(0, 3 - integerDigits)
    let scale = pow(10.0, Double(decimalPlaces))
    let truncatedValue = floor(value * scale) / scale

    return String(format: "%.\(decimalPlaces)f%@", truncatedValue, units[unitIndex])
}

func saturatingNonnegativeSum(_ values: [Int]) -> Int {
    values.reduce(0) { total, value in
        let nonnegative = max(0, value)
        let (sum, overflow) = total.addingReportingOverflow(nonnegative)
        return overflow ? Int.max : sum
    }
}

func baseKeyComponent(_ keyName: String) -> String {
    let trimmed = keyName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    if let last = trimmed.split(separator: "+").last {
        return String(last).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
}

private func canonicalBreakdownKeyPart(_ rawKeyPart: String) -> String {
    let trimmed = rawKeyPart.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    switch trimmed.uppercased() {
    case "FN", "FUNCTION", "KEY63", "KEY179", "GLOBE", "🌐":
        return "Fn"
    default:
        return trimmed
    }
}

private func canonicalBreakdownKeyName(_ keyName: String) -> String {
    let trimmed = keyName.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "+" {
        return "+"
    }

    var raw = trimmed
    var trailingPlus = false
    if raw.hasSuffix("++") {
        raw = String(raw.dropLast())
        trailingPlus = true
    }

    var rawComponents = raw
        .split(separator: "+")
        .map { canonicalBreakdownKeyPart(String($0)) }
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

func keyboardHeatmapCounts(from keyPressCounts: [String: Int]) -> [String: Int] {
    PhysicalKeyMapping.map(keyPressCounts).counts
}

func keyBreakdownDisplayCounts(from keyPressCounts: [String: Int]) -> [String: Int] {
    var aggregated: [String: Int] = [:]

    for (rawKey, rawCount) in keyPressCounts {
        let count = max(0, rawCount)
        let normalizedKey = normalizedKeyBreakdownDisplayKey(rawKey)
        guard !normalizedKey.isEmpty, count > 0 else { continue }
        aggregated[normalizedKey] = saturatingNonnegativeSum([aggregated[normalizedKey, default: 0], count])
    }

    return aggregated
}

func normalizedKeyBreakdownDisplayKey(_ rawKey: String) -> String {
    let canonicalKey = canonicalBreakdownKeyName(rawKey)
    guard !canonicalKey.isEmpty else { return "" }
    if canonicalKey == "+" {
        return canonicalKey
    }

    var workingKey = canonicalKey
    var trailingPlus = false
    if workingKey.hasSuffix("++") {
        workingKey = String(workingKey.dropLast())
        trailingPlus = true
    }

    var parts = workingKey
        .split(separator: "+")
        .map { normalizedKeyBreakdownDisplayPart(String($0)) }
        .filter { !$0.isEmpty }

    if trailingPlus {
        parts.append("+")
    }

    guard !parts.isEmpty else { return "" }

    var collapsedParts: [String] = []
    var seenParts: Set<String> = []
    for part in parts {
        if seenParts.insert(part).inserted {
            collapsedParts.append(part)
        }
    }

    return collapsedParts.joined(separator: "+")
}

func normalizedKeyBreakdownDisplayPart(_ rawPart: String) -> String {
    switch rawPart {
    case "LeftCmd", "RightCmd":
        return "Cmd"
    case "LeftOption", "RightOption":
        return "Option"
    case "LeftShift", "RightShift":
        return "Shift"
    default:
        return rawPart
    }
}


func aggregateScrollSessionCounts(_ counts: [Int]) -> Int {
    saturatingNonnegativeSum(counts)
}

/// 统计数据结构
struct DailyStats: Codable {
    var date: Date
    var keyPresses: Int
    var keyPressCounts: [String: Int]
    var leftClicks: Int
    var rightClicks: Int
    var middleClicks: Int
    var sideBackClicks: Int
    var sideForwardClicks: Int
    var mouseDistance: Double
    var scrollDistance: Double
    var scrollSessions: Int
    var appStats: [String: AppStats]
    /// 今日峰值 KPS（trailing 1-second sliding-window count 的当日最大值）
    var peakKPS: Int
    /// 今日峰值 CPS（trailing 1-second sliding-window count 的当日最大值）
    var peakCPS: Int

    init() {
        self.date = Calendar.current.startOfDay(for: Date())
        self.keyPresses = 0
        self.keyPressCounts = [:]
        self.leftClicks = 0
        self.rightClicks = 0
        self.middleClicks = 0
        self.sideBackClicks = 0
        self.sideForwardClicks = 0
        self.mouseDistance = 0
        self.scrollDistance = 0
        self.scrollSessions = 0
        self.appStats = [:]
        self.peakKPS = 0
        self.peakCPS = 0
    }

    init(date: Date) {
        self.date = Calendar.current.startOfDay(for: date)
        self.keyPresses = 0
        self.keyPressCounts = [:]
        self.leftClicks = 0
        self.rightClicks = 0
        self.middleClicks = 0
        self.sideBackClicks = 0
        self.sideForwardClicks = 0
        self.mouseDistance = 0
        self.scrollDistance = 0
        self.scrollSessions = 0
        self.appStats = [:]
        self.peakKPS = 0
        self.peakCPS = 0
    }

    /// Decode peakKPS/peakCPS from either Int or Double (legacy format)
    private static func decodeIntOrDouble(container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Int {
        if let intVal = try? container.decodeIfPresent(Int.self, forKey: key) {
            return intVal
        }
        if let doubleVal = try? container.decodeIfPresent(Double.self, forKey: key) {
            guard doubleVal.isFinite else { return 0 }
            if doubleVal >= Double(Int.max) { return Int.max }
            if doubleVal <= Double(Int.min) { return Int.min }
            return Int(doubleVal)
        }
        return 0
    }

    enum CodingKeys: String, CodingKey {
        case date
        case keyPresses
        case keyPressCounts
        case leftClicks
        case rightClicks
        case middleClicks
        case sideBackClicks
        case sideForwardClicks
        case otherClicks
        case mouseDistance
        case scrollDistance
        case scrollSessions
        case appStats
        case peakKPS
        case peakCPS
    }

    enum Breakdowns { case all, global, none }

    init(from decoder: Decoder) throws {
        try self.init(from: decoder, breakdowns: .all)
    }

    init(from decoder: Decoder, breakdowns: Breakdowns) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Calendar.current.startOfDay(for: Date())
        keyPresses = try container.decodeIfPresent(Int.self, forKey: .keyPresses) ?? 0
        keyPressCounts = breakdowns == .none ? [:] : try container.decodeIfPresent([String: Int].self, forKey: .keyPressCounts) ?? [:]
        leftClicks = try container.decodeIfPresent(Int.self, forKey: .leftClicks) ?? 0
        rightClicks = try container.decodeIfPresent(Int.self, forKey: .rightClicks) ?? 0
        middleClicks = try container.decodeIfPresent(Int.self, forKey: .middleClicks) ?? 0
        sideBackClicks = try container.decodeIfPresent(Int.self, forKey: .sideBackClicks) ?? 0
        sideForwardClicks = try container.decodeIfPresent(Int.self, forKey: .sideForwardClicks) ?? 0
        if !container.contains(.sideBackClicks) && !container.contains(.sideForwardClicks) {
            sideBackClicks = try container.decodeIfPresent(Int.self, forKey: .otherClicks) ?? 0
        }
        mouseDistance = try container.decodeIfPresent(Double.self, forKey: .mouseDistance) ?? 0
        scrollDistance = try container.decodeIfPresent(Double.self, forKey: .scrollDistance) ?? 0
        scrollSessions = try container.decodeIfPresent(Int.self, forKey: .scrollSessions) ?? 0
        appStats = [:]
        peakKPS = Self.decodeIntOrDouble(container: container, key: .peakKPS)
        peakCPS = Self.decodeIntOrDouble(container: container, key: .peakCPS)
        // Some legacy days only contain app records. They still count as active days.
        if breakdowns == .all || (breakdowns == .global && !hasActivityTotals) {
            appStats = try container.decodeIfPresent([String: AppStats].self, forKey: .appStats) ?? [:]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(keyPresses, forKey: .keyPresses)
        try container.encode(keyPressCounts, forKey: .keyPressCounts)
        try container.encode(leftClicks, forKey: .leftClicks)
        try container.encode(rightClicks, forKey: .rightClicks)
        try container.encode(middleClicks, forKey: .middleClicks)
        try container.encode(sideBackClicks, forKey: .sideBackClicks)
        try container.encode(sideForwardClicks, forKey: .sideForwardClicks)
        try container.encode(mouseDistance, forKey: .mouseDistance)
        try container.encode(scrollDistance, forKey: .scrollDistance)
        try container.encode(scrollSessions, forKey: .scrollSessions)
        try container.encode(appStats, forKey: .appStats)
        try container.encode(peakKPS, forKey: .peakKPS)
        try container.encode(peakCPS, forKey: .peakCPS)
    }

    var totalClicks: Int {
        saturatingNonnegativeSum([leftClicks, rightClicks, middleClicks, sideBackClicks, sideForwardClicks])
    }

    var hasActivityTotals: Bool {
        keyPresses > 0 ||
            leftClicks > 0 ||
            rightClicks > 0 ||
            middleClicks > 0 ||
            sideBackClicks > 0 ||
            sideForwardClicks > 0 ||
            mouseDistance > 0 ||
            scrollDistance > 0 ||
            scrollSessions > 0
    }

    var hasAnyActivity: Bool {
        hasActivityTotals || !keyPressCounts.isEmpty || !appStats.isEmpty
    }

    /// 纠错率 (Delete + ForwardDelete / Total Keys)
    var correctionRate: Double {
        guard keyPresses > 0 else { return 0 }
        let deleteLikeCount = keyPressCounts.reduce(0) { partial, entry in
            let base = baseKeyComponent(entry.key)
            guard base == "Delete" || base == "ForwardDelete" else { return partial }
            return saturatingNonnegativeSum([partial, entry.value])
        }
        return Double(deleteLikeCount) / Double(keyPresses)
    }

    /// 键鼠比 (Keys / Clicks)
    var inputRatio: Double {
        let clicks = totalClicks
        guard clicks > 0 else { return keyPresses > 0 ? Double.infinity : 0 }
        return Double(keyPresses) / Double(clicks)
    }
}

/// 有史以来统计数据结构
struct AllTimeStats {
    var totalKeyPresses: Int
    var totalLeftClicks: Int
    var totalRightClicks: Int
    var totalMiddleClicks: Int
    var totalSideBackClicks: Int
    var totalSideForwardClicks: Int
    var totalMouseDistance: Double
    var totalScrollDistance: Double
    var totalScrollSessions: Int
    var keyPressCounts: [String: Int]
    var firstDate: Date?
    var lastDate: Date?
    var activeDays: Int
    var maxDailyKeyPresses: Int
    var maxDailyKeyPressesDate: Date?
    var maxDailyClicks: Int
    var maxDailyClicksDate: Date?
    var mostActiveWeekday: Int?
    var keyActiveDays: Int
    var clickActiveDays: Int

    var totalClicks: Int {
        saturatingNonnegativeSum([
            totalLeftClicks,
            totalRightClicks,
            totalMiddleClicks,
            totalSideBackClicks,
            totalSideForwardClicks
        ])
    }

    var totalNonLeftClicks: Int {
        saturatingNonnegativeSum([
            totalRightClicks,
            totalMiddleClicks,
            totalSideBackClicks,
            totalSideForwardClicks
        ])
    }

    /// 纠错率 (Delete + ForwardDelete / Total Keys)
    var correctionRate: Double {
        guard totalKeyPresses > 0 else { return 0 }
        let deleteLikeCount = keyPressCounts.reduce(0) { partial, entry in
            let base = baseKeyComponent(entry.key)
            guard base == "Delete" || base == "ForwardDelete" else { return partial }
            return saturatingNonnegativeSum([partial, entry.value])
        }
        return Double(deleteLikeCount) / Double(totalKeyPresses)
    }

    /// 键鼠比 (Keys / Clicks)
    var inputRatio: Double {
        let clicks = totalClicks
        guard clicks > 0 else { return totalKeyPresses > 0 ? Double.infinity : 0 }
        return Double(totalKeyPresses) / Double(clicks)
    }

    static func initial() -> AllTimeStats {
        AllTimeStats(
            totalKeyPresses: 0,
            totalLeftClicks: 0,
            totalRightClicks: 0,
            totalMiddleClicks: 0,
            totalSideBackClicks: 0,
            totalSideForwardClicks: 0,
            totalMouseDistance: 0,
            totalScrollDistance: 0,
            totalScrollSessions: 0,
            keyPressCounts: [:],
            firstDate: nil,
            lastDate: nil,
            activeDays: 0,
            maxDailyKeyPresses: 0,
            maxDailyKeyPressesDate: nil,
            maxDailyClicks: 0,
            maxDailyClicksDate: nil,
            mostActiveWeekday: nil,
            keyActiveDays: 0,
            clickActiveDays: 0
        )
    }
}
