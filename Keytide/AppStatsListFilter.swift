import Foundation
#if KEYTIDE_QA
import KeytideCore
#endif

enum AppStatsSortMetric {
    case keys
    case clicks
    case scroll
}

enum AppStatsListFilter {
    static func apply(
        items: [AppStats],
        query: String,
        displayName: (AppStats) -> String,
        sortMetric: AppStatsSortMetric,
        ascending: Bool
    ) -> [AppStats] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = items.filter { item in
            normalized.isEmpty || displayName(item).localizedCaseInsensitiveContains(normalized) || item.bundleId.localizedCaseInsensitiveContains(normalized)
        }
        return filtered.sorted { lhs, rhs in
            func value(_ item: AppStats) -> Double {
                switch sortMetric {
                case .keys: return Double(item.keyPresses)
                case .clicks: return Double(item.totalClicks)
                case .scroll: return item.scrollDistance
                }
            }
            if value(lhs) != value(rhs) {
                return ascending ? value(lhs) < value(rhs) : value(lhs) > value(rhs)
            }
            let nameOrder = displayName(lhs).localizedCaseInsensitiveCompare(displayName(rhs))
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.bundleId.localizedCaseInsensitiveCompare(rhs.bundleId) == .orderedAscending
        }
    }
}
