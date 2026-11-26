import XCTest
@testable import KeytideCore

final class AppLaunchModeTests: XCTestCase {
    func testNormalLaunchIsTheDefault() {
        XCTAssertEqual(AppLaunchMode(arguments: ["KeyStats"]), .normal)
        XCTAssertEqual(AppLaunchMode(arguments: []), .normal)
    }

    func testOnlyTheExactArgumentEnablesAcceptanceInDebug() {
        let mode = AppLaunchMode(arguments: ["KeyStats", "--debug-gui-acceptance"])
        #if DEBUG
        XCTAssertEqual(mode, .guiAcceptance)
        #else
        XCTAssertEqual(mode, .normal)
        #endif
        for argument in ["--debug-gui-acceptance=true", "--debug-gui-acceptance-extra", "debug-gui-acceptance"] {
            XCTAssertEqual(AppLaunchMode(arguments: ["KeyStats", argument]), .normal)
        }
        XCTAssertEqual(AppLaunchMode(arguments: ["--debug-gui-acceptance"]), .normal)
    }

    func testAcceptanceRejectsIncompatibleHelperBeforeMonitoring() {
        XCTAssertTrue(AppLaunchMode.guiAcceptance.allowsHelperVersion(1, expected: 1))
        XCTAssertFalse(AppLaunchMode.guiAcceptance.allowsHelperVersion(0, expected: 1))
        XCTAssertFalse(AppLaunchMode.guiAcceptance.allowsHelperVersion(2, expected: 1))
    }

    func testNormalLaunchRetainsExistingHelperVersionBehavior() {
        XCTAssertTrue(AppLaunchMode.normal.allowsHelperVersion(0, expected: 1))
        XCTAssertTrue(AppLaunchMode.normal.allowsHelperVersion(1, expected: 1))
        XCTAssertTrue(AppLaunchMode.normal.allowsHelperVersion(2, expected: 1))
    }

    func testUpdaterRequiresAConfiguredPublicKeyAndNormalLaunch() {
        for key in [nil, "", "not-base64", Data(repeating: 1, count: 31).base64EncodedString(),
                    Data(repeating: 1, count: 33).base64EncodedString()] {
            XCTAssertFalse(AppLaunchMode.normal.allowsUpdater(publicKey: key, updatesEnabled: true))
        }
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        XCTAssertTrue(AppLaunchMode.normal.allowsUpdater(publicKey: key, updatesEnabled: true))
        XCTAssertFalse(AppLaunchMode.normal.allowsUpdater(publicKey: key, updatesEnabled: false))
        XCTAssertFalse(AppLaunchMode.guiAcceptance.allowsUpdater(publicKey: key, updatesEnabled: true))
    }
}

final class ApplicationIdentityMigrationTests: XCTestCase {
    func testMigrationPreservesDestinationAndDoesNotReimportAfterReset() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let source = "test.legacy." + UUID().uuidString
        let destination = "test.current." + UUID().uuidString
        defer {
            defaults.removePersistentDomain(forName: source)
            defaults.removePersistentDomain(forName: destination)
        }
        let history = Data([1, 2, 3])
        defaults.setPersistentDomain(["dailyStatsHistory": history, "menuUIStyle.v1": "geek"], forName: source)
        defaults.setPersistentDomain(["menuUIStyle.v1": "standard"], forName: destination)
        ApplicationIdentityMigration.migrate(defaults: defaults, destination: destination, source: source)
        var result = defaults.persistentDomain(forName: destination)!
        XCTAssertEqual(result["dailyStatsHistory"] as? Data, history)
        XCTAssertEqual(result["menuUIStyle.v1"] as? String, "standard")
        result.removeValue(forKey: "dailyStatsHistory")
        defaults.setPersistentDomain(result, forName: destination)
        ApplicationIdentityMigration.migrate(defaults: defaults, destination: destination, source: source)
        XCTAssertNil(defaults.persistentDomain(forName: destination)?["dailyStatsHistory"])
        XCTAssertEqual(defaults.persistentDomain(forName: source)?["dailyStatsHistory"] as? Data, history)
    }
}

final class ReleaseReadinessTests: XCTestCase {
    func testMonitoringSuccessAlreadyRunningAndFailure() {
        let status = MonitoringStatus()
        XCTAssertTrue(status.finish(token: status.begin(), ok: true, code: 0))
        XCTAssertEqual(status.state, .monitoring)
        XCTAssertTrue(status.finish(token: status.begin(), ok: false, code: 3))
        XCTAssertFalse(status.finish(token: status.begin(), ok: false, code: 2))
        XCTAssertEqual(status.state, .failed(code: 2))
        XCTAssertNotNil(status.failureDescription)
        XCTAssertFalse(status.finish(token: status.begin(), ok: false, code: 1))
        XCTAssertEqual(status.state, .failed(code: 1))
    }

    func testRetryAndDisconnectIgnoreStaleOrDuplicateReplies() {
        let status = MonitoringStatus()
        let old = status.begin()
        let current = status.begin()
        XCTAssertFalse(status.finish(token: old, ok: true, code: 0))
        XCTAssertTrue(status.finish(token: current, ok: true, code: 0))
        XCTAssertFalse(status.finish(token: current, ok: false, code: 2))
        let pending = status.begin()
        status.invalidate()
        XCTAssertFalse(status.finish(token: pending, ok: true, code: 0))
        XCTAssertEqual(status.state, .idle)
        let disconnected = status.begin()
        status.connectionLost()
        XCTAssertFalse(status.finish(token: disconnected, ok: true, code: 0))
        XCTAssertEqual(status.state, .failed(code: 2))
        status.installationFailed("fixture")
        XCTAssertNotNil(status.failureDescription)
        XCTAssertTrue(status.finish(token: status.begin(), ok: true, code: 0))
    }

    func testFourFiveSixWeekMonthHeightsContainLastRow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        for (year, month, rows) in [(2021, 2, 4), (2026, 4, 5), (2026, 3, 6)] {
            let date = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
            XCTAssertEqual(ActivityMonthLayout.height(for: date, calendar: calendar), CGFloat(75 + (rows - 1) * 43 + 35 + 8))
        }
    }

    enum Failure: Error { case activation, recovery }

    func testServiceStopWaitsForLaunchdToRemoveTheOldRegistration() throws {
        var loaded = true
        var pauses = 0
        var stopCount = 0
        try HelperServiceSwitch.stopIfLoaded(isLoaded: { loaded }, stop: { stopCount += 1 }, pause: {
            pauses += 1
            if pauses == 2 { loaded = false }
        })
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(pauses, 2)
        XCTAssertFalse(loaded)
    }

    func testServiceStopFailsWhenOldRegistrationDoesNotExit() {
        XCTAssertThrowsError(try HelperServiceSwitch.stopIfLoaded(isLoaded: { true }, stop: {}, pause: {})) {
            XCTAssertTrue($0 is HelperServiceSwitch.RemovalTimedOut)
        }
    }

    func testServiceStopAllowsConcurrentRemoval() throws {
        var loaded = true
        try HelperServiceSwitch.stopIfLoaded(isLoaded: { loaded }, stop: {
            loaded = false
            throw Failure.recovery
        }, pause: { XCTFail("The service already exited") })
    }

    private func withFixture(_ body: (URL, URL, URL, Data) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old.plist")
        let new = root.appendingPathComponent("new.plist")
        let data = Data("original".utf8)
        try data.write(to: old)
        try Data("new".utf8).write(to: new)
        try body(root, old, new, data)
    }

    func testServiceSwitchSuccessStopsOldBeforeActivation() throws {
        try withFixture { _, old, new, data in
            var operations: [String] = []
            let transaction = HelperServiceSwitch(fileManager: .default, unload: { operations.append($0) }, load: { _ in XCTFail("No recovery expected") })
            try transaction.perform(legacy: .init(url: old, label: "old", data: data, wasLoaded: true), newURL: new, newLabel: "active") {
                XCTAssertEqual(operations, ["old"])
                operations.append("activate")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
            XCTAssertEqual(operations, ["old", "activate"])
        }
    }

    func testActivationFailureRestoresOldRegistrationAndLoading() throws {
        try withFixture { _, old, new, data in
            var operations: [String] = []
            let transaction = HelperServiceSwitch(fileManager: .default, unload: { operations.append($0) }, load: { url in
                XCTAssertEqual(try Data(contentsOf: url), data)
                operations.append("restore")
            })
            XCTAssertThrowsError(try transaction.perform(legacy: .init(url: old, label: "old", data: data, wasLoaded: true), newURL: new, newLabel: "active") { throw Failure.activation })
            XCTAssertEqual(operations, ["old", "active", "restore"])
            XCTAssertEqual(try Data(contentsOf: old), data)
            XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
        }
    }

    func testOriginallyUnloadedServiceIsNotStartedDuringRecovery() throws {
        try withFixture { _, old, new, data in
            let previous = Data("previous-new".utf8)
            let transaction = HelperServiceSwitch(fileManager: .default, unload: { _ in }, load: { _ in XCTFail("Was not loaded") })
            XCTAssertThrowsError(try transaction.perform(legacy: .init(url: old, label: "old", data: data, wasLoaded: false), newURL: new, newLabel: "active", previousNewData: previous) { throw Failure.activation })
            XCTAssertEqual(try Data(contentsOf: new), previous)
        }
    }

    func testDebugActivationFailureOnlyUnloadsTheDebugService() throws {
        try withFixture { _, _, new, _ in
            let debugLabel = "com.xuanlprk.KeyTide.debug.helper"
            var unloaded: [String] = []
            let transaction = HelperServiceSwitch(fileManager: .default, unload: { unloaded.append($0) }, load: { _ in
                XCTFail("No legacy service to restore")
            })
            XCTAssertThrowsError(try transaction.perform(legacy: nil, newURL: new, newLabel: debugLabel) {
                throw Failure.activation
            })
            XCTAssertEqual(unloaded, [debugLabel])
        }
    }

    func testRecoveryFailureIsReportedAndDoesNotStartBothServices() throws {
        try withFixture { _, old, new, data in
            let transaction = HelperServiceSwitch(fileManager: .default, unload: { label in
                if label != "old" { throw Failure.recovery }
            }, load: { _ in XCTFail("Cannot restart old before new stopped") })
            XCTAssertThrowsError(try transaction.perform(legacy: .init(url: old, label: "old", data: data, wasLoaded: true), newURL: new, newLabel: "active") { throw Failure.activation }) {
                XCTAssertTrue($0 is HelperServiceSwitch.RecoveryFailure)
            }
            XCTAssertEqual(try Data(contentsOf: old), data)
        }
    }

    func testOnlyExactLegacyIdentityIsEligible() throws {
        try withFixture { home, old, _, _ in
            let label = "com.xuanlprk.KeyStatsMac.helper"
            let binary = home.appendingPathComponent("Library/Application Support/KeyStatsMac/Helper/KeyStatsHelper.app/Contents/MacOS/KeyStatsHelper").path
            for path in ["/unrelated/binary", binary] {
                let plist: [String: Any] = ["Label": label, "ProgramArguments": [path], "MachServices": [label: true]]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: old)
                let result = try HelperServiceSwitch.matchingLegacy(at: old, home: home, isLoaded: { _ in true })
                XCTAssertEqual(result != nil, path == binary)
                XCTAssertEqual(try Data(contentsOf: old), data)
            }
        }
    }
}

final class OnboardingProgressTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "Keytide.WelcomeTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }
    func testFreshUserResumesSetupWithoutDependingOnAnalytics() {
        withDefaults { defaults in
            defaults.set(true, forKey: "analyticsInstallTracked")
            let progress = OnboardingProgress(defaults: defaults)
            XCTAssertEqual(progress.stage, .welcome)
            XCTAssertTrue(progress.shouldPresentAutomatically)
            XCTAssertNil(defaults.object(forKey: "analytics.optIn.v1"))
            progress.beginSetup()
            defaults.set(Data(), forKey: "dailyStats")
            let resumed = OnboardingProgress(defaults: defaults)
            XCTAssertEqual(resumed.stage, .setup)
            XCTAssertTrue(resumed.shouldPresentAutomatically)
        }
    }
    func testExistingUsersAreNotInterruptedButCanCompleteManualGuide() {
        withDefaults { defaults in
            defaults.set(Data(), forKey: "dailyStatsHistory")
            let progress = OnboardingProgress(defaults: defaults)
            XCTAssertFalse(progress.shouldPresentAutomatically)
            XCTAssertFalse(progress.usesWelcomeExperience)
            XCTAssertFalse(progress.complete(isMonitoring: false))
            XCTAssertTrue(progress.complete(isMonitoring: true))
            XCTAssertEqual(OnboardingProgress(defaults: defaults).stage, .completed)
        }
    }
    func testOnlyRealMonitoringCompletesGuide() {
        withDefaults { defaults in
            let progress = OnboardingProgress(defaults: defaults)
            progress.beginSetup()
            XCTAssertFalse(progress.complete(isMonitoring: false))
            XCTAssertEqual(progress.stage, .setup)
            XCTAssertTrue(progress.complete(isMonitoring: true))
            let reopened = OnboardingProgress(defaults: defaults)
            XCTAssertFalse(reopened.shouldPresentAutomatically)
            XCTAssertTrue(reopened.usesWelcomeExperience)
        }
    }
}
