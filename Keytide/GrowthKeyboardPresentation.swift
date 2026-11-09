import Foundation

struct GrowthKeyboardKeyUsage: Equatable {
    let id: String
    let count: Int
    var progress: Double { KeyboardUsageProgress.progress(for: count) }
}

struct GrowthKeyboardKeyInsight: Equatable {
    let usage: GrowthKeyboardKeyUsage
    let share: Double
    let rank: Int?

    init(id: String, in values: [GrowthKeyboardKeyUsage]) {
        usage = values.first { $0.id == id } ?? GrowthKeyboardKeyUsage(id: id, count: 0)
        // These are key participations, not physical input events. A chord can
        // contribute to several keys, so the shares need not describe events.
        let total = values.reduce(0.0) { $0 + Double(max(0, $1.count)) }
        share = total > 0 ? Double(max(0, usage.count)) / total : 0
        let count = max(0, usage.count)
        rank = count > 0 ? values.filter { max(0, $0.count) > count }.count + 1 : nil
    }
}

struct GrowthKeyboardSidebarSelection: Equatable {
    let name: String
    let countValue: Int
    let count: String
    let share: Double
    let rank: String?
}

struct GrowthKeyboardFrame {
    let dayKey: String
    let date: Date
    let dayIndex: Int
    let snapshot: CumulativeKeyboardSnapshot
    let physical: PhysicalKeyMappingResult
    var interval: KeyboardUsageInterval? = nil

    var hasPartialDetails: Bool { snapshot.detailedKeyPresses < snapshot.totalKeyPresses }

    var keyUsages: [GrowthKeyboardKeyUsage] {
        KeyboardLayout.macStyle.keys.map { key in
            let count = physical.counts[key.id] ?? key.fallbackCountIDs
                .compactMap { physical.counts[$0] }.first ?? 0
            return GrowthKeyboardKeyUsage(id: key.id, count: count)
        }
    }
}

/// A session's display-aggregated snapshots. No files, defaults, schema or input monitoring.
struct GrowthKeyboardPresentation {
    let snapshots: [CumulativeKeyboardSnapshot]
    let period: KeyboardTrackingPeriod
    let today: Date
    let dayCount: Int
    let calendar: Calendar
    let dailyUsage: [KeyboardUsageDay]
    private let formatter: DateFormatter

    /// The production page and tests use this exact adapter, including unsaved
    /// currentStats, established history normalization and Sync display aggregation.
    static func load(from manager: StatsManager, now: Date = Date(),
                     calendar: Calendar = .current) -> GrowthKeyboardPresentation? {
        let timeline = manager.cumulativeKeyboardTimeline()
        guard let period = manager.keyboardTrackingPeriod() else { return nil }
        return GrowthKeyboardPresentation(timeline: timeline, period: period, now: now, calendar: calendar, dailyUsage: manager.keyboardDailyUsage())
    }

    init?(timeline: [CumulativeKeyboardSnapshot], period: KeyboardTrackingPeriod,
          now: Date, calendar: Calendar, dailyUsage: [KeyboardUsageDay] = []) {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        let todayKey = formatter.string(from: today)
        let bounded = timeline.filter { $0.dayKey <= todayKey }.sorted { $0.dayKey < $1.dayKey }
        guard let count = period.dayIndex(for: todayKey), count > 0,
              bounded.contains(where: { $0.dayKey == period.firstTrackedDayKey }) else { return nil }
        self.dailyUsage = dailyUsage
        self.snapshots = bounded
        self.period = period
        self.today = today
        self.dayCount = count
        self.calendar = calendar
        self.formatter = formatter
    }

    func date(at offset: Int) -> Date {
        calendar.date(byAdding: .day, value: min(dayCount - 1, max(0, offset)), to: period.firstTrackedDate)!
    }

    func offset(for date: Date) -> Int {
        let days = calendar.dateComponents([.day], from: period.firstTrackedDate,
                                          to: calendar.startOfDay(for: date)).day ?? 0
        return min(dayCount - 1, max(0, days))
    }

    /// Inclusive local calendar dates, using daily records rather than subtracting
    /// potentially saturated cumulative totals. Missing days remain explicit.
    func intervalFrame(from start: Date, through end: Date) -> GrowthKeyboardFrame {
        let a = min(calendar.startOfDay(for: start), today)
        let b = min(calendar.startOfDay(for: end), today)
        let first = min(a, b), last = max(a, b)
        let firstKey = formatter.string(from: first), lastKey = formatter.string(from: last)
        let records = dailyUsage.filter { $0.dayKey >= firstKey && $0.dayKey <= lastKey }
        var total = 0, details = 0, counts: [String: Int] = [:]
        func add(_ a: Int, _ b: Int) -> Int {
            let (sum, overflow) = a.addingReportingOverflow(max(0, b))
            return overflow ? Int.max : sum
        }
        for day in records {
            total = add(total, day.totalKeyPresses)
            for (key, count) in day.keyPressCounts where count > 0 {
                counts[key] = add(counts[key] ?? 0, count)
                details = add(details, count)
            }
        }
        let days = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        let interval = KeyboardUsageInterval(start: first, end: last, recordedDays: records.count,
            expectedDays: days, hasPartialDetails: records.contains { day in
                day.keyPressCounts.values.reduce(0) { add($0, $1) } < day.totalKeyPresses
            })
        let snapshot = CumulativeKeyboardSnapshot(dayKey: lastKey, date: last,
            totalKeyPresses: total, keyPressCounts: counts, detailedKeyPresses: details)
        return GrowthKeyboardFrame(dayKey: lastKey, date: last, dayIndex: offset(for: last) + 1,
            snapshot: snapshot, physical: PhysicalKeyMapping.map(counts), interval: interval)
    }

    /// Calendar gaps reuse the latest snapshot, but display the requested date / Day N.
    /// Cached binary search: date scrubbing never rebuilds history.
    func frame(at offset: Int) -> GrowthKeyboardFrame {
        let date = date(at: offset)
        let dayKey = formatter.string(from: date)
        var lower = 0, upper = snapshots.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if snapshots[middle].dayKey <= dayKey { lower = middle + 1 }
            else { upper = middle }
        }
        let snapshot = snapshots[lower - 1]
        return GrowthKeyboardFrame(dayKey: dayKey, date: date,
            dayIndex: period.dayIndex(for: dayKey)!, snapshot: snapshot,
            physical: PhysicalKeyMapping.map(snapshot.keyPressCounts))
    }
}

/// Restricted, display-aggregated daily data; no per-app identities or raw events.
struct KeyboardUsageDay {
    let dayKey: String
    let totalKeyPresses: Int
    let keyPressCounts: [String: Int]
}

struct KeyboardUsageInterval {
    let start: Date
    let end: Date
    let recordedDays: Int
    let expectedDays: Int
    let hasPartialDetails: Bool
    var missingDays: Int { max(0, expectedDays - recordedDays) }
}
