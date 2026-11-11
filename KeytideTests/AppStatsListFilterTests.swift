import XCTest
@testable import KeytideCore

final class AppStatsListFilterTests: XCTestCase {
    private func app(_ id: String, _ name: String, keys: Int = 0, clicks: Int = 0, scroll: Double = 0) -> AppStats {
        var app = AppStats(bundleId: id, displayName: name)
        app.keyPresses = keys
        app.leftClicks = clicks
        app.scrollDistance = scroll
        return app
    }

    func testSearchMatchesNameAndBundleIDCaseInsensitively() {
        let items = [app("com.apple.Safari", "Safari"), app("com.example.editor", "Nova"), app("org.mozilla.firefox", "Firefox")]
        XCTAssertEqual(AppStatsListFilter.apply(items: items, query: "NOVA", displayName: { $0.displayName }, sortMetric: .keys, ascending: false).map(\.bundleId), ["com.example.editor"])
        XCTAssertEqual(AppStatsListFilter.apply(items: items, query: "COM.APPLE", displayName: { $0.displayName }, sortMetric: .keys, ascending: false).map(\.bundleId), ["com.apple.Safari"])
        XCTAssertEqual(AppStatsListFilter.apply(items: items, query: "   ", displayName: { $0.displayName }, sortMetric: .keys, ascending: false).count, 3)
        XCTAssertTrue(AppStatsListFilter.apply(items: items, query: "not installed", displayName: { $0.displayName }, sortMetric: .keys, ascending: false).isEmpty)
    }

    func testEveryMetricSupportsBothDirections() {
        let items = [app("a", "Alpha", keys: 3, clicks: 1, scroll: 5), app("b", "Beta", keys: 1, clicks: 4, scroll: 2)]
        XCTAssertEqual(AppStatsListFilter.apply(items: items, query: "", displayName: { $0.displayName }, sortMetric: .keys, ascending: true).map(\.bundleId), ["b", "a"])
        XCTAssertEqual(AppStatsListFilter.apply(items: items, query: "", displayName: { $0.displayName }, sortMetric: .clicks, ascending: false).map(\.bundleId), ["b", "a"])
        XCTAssertEqual(AppStatsListFilter.apply(items: items, query: "", displayName: { $0.displayName }, sortMetric: .scroll, ascending: true).map(\.bundleId), ["b", "a"])
    }

    func testTieUsesNameThenBundleIDRegardlessOfDirection() {
        let items = [app("z", "Same", keys: 1), app("b", "alpha", keys: 1), app("a", "Same", keys: 1)]
        for ascending in [false, true] {
            XCTAssertEqual(AppStatsListFilter.apply(items: items, query: "", displayName: { $0.displayName }, sortMetric: .keys, ascending: ascending).map(\.bundleId), ["b", "a", "z"])
        }
    }
}
