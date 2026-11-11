import AppKit
import XCTest
@testable import KeytideCore

final class ActivityHeatmapTests: XCTestCase {
    private func days(_ count: Int) -> [ActivityHeatmapView.DayActivity] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_730_000_000))
        return (0..<count).map {
            .init(date: calendar.date(byAdding: .day, value: $0, to: start)!, keyPresses: $0, clicks: 0)
        }
    }

    private func key(_ code: UInt16, in view: ActivityHeatmapView) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                    isARepeat: false, keyCode: code)!
        view.keyDown(with: event)
    }

    func testNavigationClampsAndOnlyReturnOpensExactDate() {
        let view = ActivityHeatmapView(frame: NSRect(x: 0, y: 0, width: 500, height: 140))
        let data = days(15)
        view.activityData = data
        var opened: [Date] = []
        view.onOpenDay = { opened.append($0) }
        view.selectDay(at: 7)
        key(123, in: view)
        XCTAssertEqual(view.selectedIndex, 0)
        key(126, in: view)
        XCTAssertEqual(view.selectedIndex, 0)
        key(124, in: view)
        key(125, in: view)
        XCTAssertEqual(view.selectedIndex, 8)
        XCTAssertTrue(opened.isEmpty)
        key(36, in: view)
        XCTAssertEqual(opened, [data[8].date])
        key(119, in: view)
        key(124, in: view)
        XCTAssertEqual(view.selectedIndex, 14)
        key(115, in: view)
        XCTAssertEqual(view.selectedIndex, 0)
    }

    func testRefreshPreservesDateRatherThanIndexAndClearsRemovedDate() {
        let view = ActivityHeatmapView()
        let data = days(15)
        view.activityData = data
        view.selectDay(at: 7)
        view.activityData = Array(data.dropFirst())
        XCTAssertEqual(view.selectedIndex, 6)
        var opened: Date?
        view.onOpenDay = { opened = $0 }
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(opened, data[7].date)
        view.activityData = Array(data.suffix(3))
        XCTAssertNil(view.selectedIndex)
        XCTAssertFalse(view.accessibilityPerformPress())
    }

    func testZeroDayCanOpenAndEscapeClearsSelection() {
        let view = ActivityHeatmapView()
        let data = days(1)
        view.activityData = data
        var opened: Date?
        view.onOpenDay = { opened = $0 }
        view.selectDay(at: 0)
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(opened, data[0].date)
        key(53, in: view)
        XCTAssertNil(view.selectedIndex)
        XCTAssertFalse(view.accessibilityPerformPress())
    }

    func testEmptyRefreshRemovesFocusEligibilityAndStaleAction() {
        let view = ActivityHeatmapView()
        view.activityData = days(2)
        view.selectDay(at: 1)
        view.activityData = []
        view.onOpenDay = { _ in XCTFail("Empty calendar must not open an old date") }
        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertNil(view.selectedIndex)
        XCTAssertFalse(view.accessibilityPerformPress())
        view.selectDay(at: 0)
        XCTAssertNil(view.selectedIndex)
    }
}

extension ActivityHeatmapTests {
    func testMetricUsesIndependentDailyFieldsAndPreservesSelection() {
        let view = ActivityHeatmapView()
        let first = ActivityHeatmapView.DayActivity(date: Date(timeIntervalSince1970: 0), keyPresses: 10, clicks: 2)
        let second = ActivityHeatmapView.DayActivity(date: Date(timeIntervalSince1970: 86400), keyPresses: 0, clicks: 8)
        view.activityData = [first, second]
        view.selectDay(at: 1)
        XCTAssertEqual(ActivityHeatmapView.Metric.combined.value(for: first), 12)
        XCTAssertEqual(ActivityHeatmapView.Metric.keys.value(for: second), 0)
        view.metric = .clicks
        XCTAssertEqual(ActivityHeatmapView.Metric.clicks.value(for: second), 8)
        XCTAssertEqual(view.selectedActivity?.date, second.date)
        let spoken = (view.accessibilityValue() as? String) ?? ""
        let expectedDetail = String(format: NSLocalizedString("heatmap.detailFormat", comment: ""), second.keyPresses, second.clicks)
        XCTAssertTrue(spoken.contains(expectedDetail), spoken)
        view.metric = .keys
        XCTAssertEqual(view.selectedActivity?.clicks, 8)
        XCTAssertFalse(view.metric.title.isEmpty)
    }
}

extension ActivityHeatmapTests {
    func testRemovingSelectedDateNotifiesEmptySelectionOnce() {
        let view = ActivityHeatmapView()
        view.activityData = days(2)
        view.selectDay(at: 0)
        var received: [ActivityHeatmapView.DayActivity?] = []
        view.onSelectionChanged = { received.append($0) }
        view.activityData = Array(view.activityData.suffix(1))
        XCTAssertEqual(received.count, 1)
        XCTAssertNil(received[0])
        XCTAssertNil(view.selectedActivity)
    }
}
