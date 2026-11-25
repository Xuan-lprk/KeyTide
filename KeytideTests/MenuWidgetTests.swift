import Foundation
import XCTest
@testable import KeytideCore

final class MenuWidgetTests: XCTestCase {
    func testMenuPresentationSwitchPreservesWidgetConfiguration() {
        withDefaults { defaults in
            XCTAssertEqual(MenuPresentation.load(from: defaults), .widgets)
            let widgets = [MenuWidget(kind: .heatmap, style: .geek, heatmapEffect: .constellation)]
            MenuWidgetPreferences.save(widgets, to: defaults)

            MenuPresentation.classic.save(to: defaults)
            XCTAssertEqual(MenuPresentation.load(from: defaults), .classic)
            XCTAssertEqual(MenuWidgetPreferences.load(from: defaults), widgets)

            MenuPresentation.geek.save(to: defaults)
            XCTAssertEqual(MenuPresentation.load(from: defaults), .geek)
            XCTAssertEqual(MenuPresentation.load(from: defaults).popoverStyle, .geek)
            XCTAssertEqual(MenuWidgetPreferences.load(from: defaults), widgets)

            MenuPresentation.widgets.save(to: defaults)
            XCTAssertEqual(MenuPresentation.load(from: defaults), .widgets)
            XCTAssertEqual(MenuWidgetPreferences.load(from: defaults), widgets)
        }
    }

    func testPreviouslySavedClassicModeKeepsItsRendererUntilExplicitlyChanged() {
        withDefaults { defaults in
            defaults.set("classic", forKey: "menu.presentation.v1")
            XCTAssertEqual(MenuPresentation.load(from: defaults).popoverStyle, .standard)

            defaults.set("geek", forKey: MenuUIStyle.defaultsKey)
            XCTAssertEqual(MenuPresentation.load(from: defaults), .geek)

            MenuPresentation.classic.save(to: defaults)
            XCTAssertEqual(MenuPresentation.load(from: defaults).popoverStyle, .standard)
            XCTAssertEqual(defaults.string(forKey: MenuUIStyle.defaultsKey), "geek")
        }
    }

    func testFreshLayoutIsEmptyAndClearedLayoutDoesNotMigrateAgain() {
        withDefaults { defaults in
            XCTAssertEqual(MenuWidgetPreferences.load(from: defaults), [])
            defaults.set("geek", forKey: MenuUIStyle.defaultsKey)
            let migrated = MenuWidgetPreferences.load(from: defaults)
            XCTAssertEqual(migrated.map(\.kind), [.pulse, .today, .keys, .history, .mouse])
            XCTAssertTrue(migrated.allSatisfy { $0.style == .geek })
            XCTAssertEqual(MenuWidgetPreferences.load(from: defaults), migrated)

            MenuWidgetPreferences.save([], to: defaults)
            XCTAssertEqual(MenuWidgetPreferences.load(from: defaults), [])
        }
    }

    func testLegacyHeatmapPreservesClassicGreenAndTrailEffect() {
        withDefaults { defaults in
            defaults.set("keyboardHeatmap", forKey: MenuUIStyle.defaultsKey)
            defaults.set(-1, forKey: KeyboardHeatmapTheme.defaultsKey)
            defaults.set("trail", forKey: KeyboardHeatmapEffect.defaultsKey)
            let migrated = MenuWidgetPreferences.load(from: defaults)
            XCTAssertEqual(migrated.map(\.kind), [.heatmap])
            XCTAssertEqual(migrated.first?.heatmapTheme, .green)
            XCTAssertEqual(migrated.first?.heatmapEffect, .constellation)
            XCTAssertEqual(MenuWidgetPreferences.load(from: defaults), migrated)
        }
    }

    func testDuplicateKindsKeepIndependentSettingsAndOrder() {
        withDefaults { defaults in
            let keys = MenuWidget(kind: .history, width: .half)
            let clicks = MenuWidget(kind: .history, style: .geek, metric: .clicks, monthly: true, bars: true)
            let blue = MenuWidget(kind: .heatmap)
            let green = MenuWidget(kind: .heatmap, heatmapThemeRGB: nil, heatmapEffect: .constellation)
            let layout = [clicks, blue, keys, green]

            MenuWidgetPreferences.save(layout, to: defaults)
            XCTAssertEqual(MenuWidgetPreferences.load(from: defaults), layout)
            XCTAssertEqual(Set(layout.map(\.id)).count, layout.count)
        }
    }

    func testRowsPairOnlyAdjacentHalfWidthWidgets() {
        let top = MenuWidget(kind: .today, width: .half)
        let heatmap = MenuWidget(kind: .heatmap, width: .half)
        let left = MenuWidget(kind: .pulse, width: .half)
        let right = MenuWidget(kind: .mouse, width: .half)
        let last = MenuWidget(kind: .history, width: .half)
        let layout = [top, heatmap, left, right, last]

        XCTAssertEqual(MenuWidget.rows(for: layout), [[top], [heatmap], [left, right], [last]])
        XCTAssertEqual(MenuWidget.rows(for: layout, allowsHalfWidth: false), layout.map { [$0] })
    }

    func testAdditionalStatisticsWidgetsRoundTripWithTheirOwnOptions() {
        withDefaults { defaults in
            let calendar = MenuWidget(kind: .calendar, style: .geek, metric: .combined)
            let daily = MenuWidget(kind: .activity, width: .half, monthly: true)
            let apps = MenuWidget(kind: .apps, width: .half, metric: .scroll)
            let totals = MenuWidget(kind: .totals)
            let peaks = MenuWidget(kind: .peaks, width: .half)
            let widgets = [calendar, daily, apps, totals, peaks]

            MenuWidgetPreferences.save(widgets, to: defaults)
            XCTAssertEqual(MenuWidgetPreferences.load(from: defaults), widgets)
            XCTAssertEqual(MenuWidget.rows(for: widgets), [[calendar], [daily, apps], [totals], [peaks]])
            XCTAssertEqual(calendar.displayMetric, .combined)
            XCTAssertEqual(apps.displayMetric, .scroll)
            XCTAssertEqual(MenuWidget(kind: .history, metric: .combined).displayMetric, .keys)
        }
    }

    private func withDefaults(_ run: (UserDefaults) -> Void) {
        let suite = "Keytide.MenuWidgetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        run(defaults)
    }
}
