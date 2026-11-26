import AppKit
import CryptoKit
import IOKit.hidsystem
import XCTest
@testable import KeytideHelper

private final class SyntheticTrackpadCapture: TrackpadCapturing {
    var onFrame: ((TrackpadFrame, Double) -> Void)?
    private(set) var running = false

    func start() -> Bool { running = true; return true }
    func stop() { running = false }

    func emit(_ frame: TrackpadFrame, receivedAt: Double) {
        if running { onFrame?(frame, receivedAt) }
    }
}

private final class SyntheticInputTap: InputEventTap, EventPayloadSink {
    var running = false
    var tracksReplay = false
    weak var input: HelperInputService?

    func start(sink: EventPayloadSink) -> Int {
        if running { return HelperErrorCode.alreadyMonitoring }
        running = true
        return HelperErrorCode.none
    }

    func stop() { running = false; tracksReplay = false }
    func setReplayRecordingEnabled(_ enabled: Bool) { tracksReplay = enabled }
    func forward(payload: [String: Any]) { if running { input?.receive(payload) } }
}

/// Synthetic payload checks only: no native event tap, XPC connection, or service launch.
final class HelperContractTests: XCTestCase {
    func testBackgroundDefaultAndSavedOptOut() throws {
        let suite = "Keytide-background-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let marker = folder.appendingPathComponent("background-enabled")
        let tap = SyntheticInputTap()
        let input = HelperInputService(tap: tap, defaults: defaults, marker: marker)
        input.sink = tap

        XCTAssertTrue(BackgroundInputPreference.isEnabled(in: defaults))
        input.restore()
        input.control(.enableBackground, argument: Data()) { _, applied in XCTAssertFalse(applied) }
        XCTAssertFalse(tap.running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        defaults.set(false, forKey: BackgroundInputPreference.appliedKey)
        XCTAssertFalse(BackgroundInputPreference.isEnabled(in: defaults), "Preserve a previously saved choice")
        defaults.set(true, forKey: BackgroundInputPreference.requestedKey)
        XCTAssertTrue(BackgroundInputPreference.isEnabled(in: defaults))
        XCTAssertEqual(input.attach(), HelperErrorCode.none)
        input.control(.enableBackground, argument: Data()) { _, applied in XCTAssertTrue(applied) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(tap.tracksReplay)

        // Closing before the UI sends its last command still respects its saved choice.
        defaults.set(false, forKey: BackgroundInputPreference.requestedKey)
        input.detach()
        XCTAssertFalse(tap.running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        try Data([1]).write(to: marker)
        defaults.set(true, forKey: BackgroundInputPreference.appliedKey)
        let restartedTap = SyntheticInputTap()
        let restarted = HelperInputService(tap: restartedTap, defaults: defaults, marker: marker)
        restarted.sink = restartedTap
        restarted.restore()
        XCTAssertFalse(restartedTap.running, "A stale marker cannot override a saved opt-out")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testDetachedInputSurvivesQuitAndRelaunchWithoutTheUI() throws {
        let suite = "Keytide-detached-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let marker = folder.appendingPathComponent("background-enabled")
        let keys = folder.appendingPathComponent("key-replay")
        let touches = folder.appendingPathComponent("trackpad-replay")
        let secret = SymmetricKey(size: .bits256)
        let day = Date()

        func makeServices() -> (HelperInputService, SyntheticInputTap, HelperTrackpadService,
                                TrackpadRecording, SyntheticTrackpadCapture) {
            let tap = SyntheticInputTap()
            let keyboard = HelperKeyReplayWriter(defaults: defaults, directory: keys) { _, _ in secret }
            let input = HelperInputService(tap: tap, defaults: defaults, marker: marker, keyboard: keyboard)
            input.sink = tap
            tap.input = input
            let device = SyntheticTrackpadCapture()
            let trackpad = TrackpadRecording(capture: device, defaults: defaults, directory: touches,
                                             keyProvider: { _ in secret }, uptime: { 10 })
            let trackpadService = HelperTrackpadService(recorder: trackpad)
            trackpadService.restore()
            input.onPresenceChange = { connected, allowed in
                trackpadService.updatePresence(connected: connected, allowsDetached: allowed)
            }
            return (input, tap, trackpadService, trackpad, device)
        }

        func press(_ code: UInt16, on tap: SyntheticInputTap) throws {
            for (down, phase) in [(true, CGEventType.keyDown), (false, .keyUp)] {
                let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
                event.timestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
                guard let payload = PayloadBuilder.build(from: event, type: phase, recordsReplay: tap.tracksReplay) else {
                    if down { XCTFail("Missing key-down payload") }
                    continue
                }
                tap.forward(payload: payload)
            }
        }

        do {
            let (input, tap, trackpad, writer, device) = makeServices()
            var keepAlive = false
            input.onKeepAlive = { keepAlive = $0 }
            try Data([1]).write(to: marker)
            input.restore()
            XCTAssertFalse(tap.running, "A marker alone must never start recording")
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

            XCTAssertEqual(input.attach(), HelperErrorCode.none)
            XCTAssertFalse(tap.tracksReplay)
            try press(0, on: tap)
            input.control(.enableBackground, argument: Data()) { _, ok in XCTAssertTrue(ok) }
            XCTAssertTrue(keepAlive)
            XCTAssertFalse(tap.tracksReplay, "Background consent must not enable detailed keyboard replay")
            XCTAssertFalse(device.running, "Background consent must not enable touchpad replay")
            XCTAssertFalse(FileManager.default.fileExists(atPath: keys.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: touches.path))
            let keyEnabled = expectation(description: "Keyboard replay enabled")
            input.control(.enableKeyboardReplay, argument: Data()) { _, ok in
                XCTAssertTrue(ok); keyEnabled.fulfill()
            }
            let trackpadEnabled = expectation(description: "Trackpad replay enabled")
            trackpad.control(.enable) { _, ok in
                XCTAssertTrue(ok); trackpadEnabled.fulfill()
            }
            wait(for: [keyEnabled, trackpadEnabled], timeout: 3)
            trackpad.control(.startPreview) { _, ok in XCTAssertTrue(ok) }
            var previewPackets = 0
            trackpad.sendPreview = { _ in previewPackets += 1 }

            input.detach()
            trackpad.detachPreview()
            XCTAssertFalse(input.connected)
            XCTAssertTrue(tap.running)
            XCTAssertTrue(tap.tracksReplay)
            XCTAssertTrue(device.running)
            try press(1, on: tap)
            try press(1, on: tap)
            tap.forward(payload: [HelperPayloadFields.type: CGEventType.leftMouseDown.rawValue,
                                  HelperPayloadFields.buttonRole: ButtonRole.primary])
            tap.forward(payload: [HelperPayloadFields.type: CGEventType.mouseMoved.rawValue,
                                  HelperPayloadFields.locationX: 0, HelperPayloadFields.locationY: 0])
            tap.forward(payload: [HelperPayloadFields.type: CGEventType.mouseMoved.rawValue,
                                  HelperPayloadFields.locationX: 3, HelperPayloadFields.locationY: 4])
            tap.forward(payload: [HelperPayloadFields.type: CGEventType.scrollWheel.rawValue,
                                  HelperPayloadFields.scrollDX: 0, HelperPayloadFields.scrollDY: 2])
            let contact = TrackpadContact(identity: 1, state: 4, sourceTime: 12,
                position: CGPoint(x: 0.2, y: 0.3), rawPressure: 14)
            device.emit(TrackpadFrame(sourceTime: 12, ordinal: 1, contacts: [contact]), receivedAt: 12)

            let flushed = expectation(description: "Read touchpad replay recorded with no UI")
            writer.load(day: day) { reader in
                guard let reader else { XCTFail("Missing background record"); flushed.fulfill(); return }
                reader.take(through: 1) { frames, _, failed in
                    XCTAssertFalse(failed)
                    XCTAssertEqual(frames.flatMap(\.contacts).first?.position, contact.position)
                    flushed.fulfill()
                }
            }
            wait(for: [flushed], timeout: 3)
            XCTAssertEqual(previewPackets, 0)

            let reopened = expectation(description: "A reopened app receives the retained aggregates")
            input.onSnapshot = { data in
                defer { reopened.fulfill() }
                let snapshotFields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                XCTAssertEqual(Set(snapshotFields?.keys.map { $0 } ?? []),
                               ["current", "history", "kps", "cps", "sampledAt", "calibrationFactor"])
                guard let snapshot = try? JSONDecoder().decode(StatsManager.CaptureSnapshot.self, from: data) else {
                    return XCTFail("Invalid snapshot")
                }
                XCTAssertEqual(snapshot.current.keyPresses, 3)
                XCTAssertEqual(snapshot.current.leftClicks, 1)
                XCTAssertEqual(snapshot.current.mouseDistance, 5)
                XCTAssertEqual(snapshot.current.scrollDistance, 20)
                XCTAssertNotNil(snapshot.history)
            }
            XCTAssertEqual(input.attach(), HelperErrorCode.alreadyMonitoring)
            wait(for: [reopened], timeout: 3)
            input.onSnapshot = nil
            input.detach()
            input.finish()
            trackpad.finish()
        }

        let replayStore = try KeyReplayStore(directory: keys, key: secret)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dayKey = formatter.string(from: day)
        let replay = try replayStore.load(day: dayKey)
        XCTAssertFalse(replay.hasUnreadableChunks)
        XCTAssertEqual(replay.entries.map { $0.event.keyCode }, [1, 1, 1, 1])
        XCTAssertEqual(replay.entries.map { $0.event.phase }, [.down, .up, .down, .up])
        for directory in [keys, touches] {
            let dayDirectory = directory.appendingPathComponent(dayKey, isDirectory: true)
            for url in [directory, dayDirectory] {
                let resourceValues = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
                XCTAssertEqual(resourceValues.isExcludedFromBackup, true, "Replay directories must be excluded from macOS backups")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        let (restarted, tap, trackpad, _, device) = makeServices()
        var keepAlive = false
        restarted.onKeepAlive = { keepAlive = $0 }
        restarted.restore()
        XCTAssertTrue(keepAlive)
        XCTAssertTrue(tap.running)
        XCTAssertTrue(tap.tracksReplay)
        XCTAssertTrue(device.running)
        XCTAssertFalse(restarted.connected, "Login restoration cannot depend on launching the App")
        try press(2, on: tap)
        XCTAssertEqual(restarted.attach(), HelperErrorCode.alreadyMonitoring)
        restarted.control(.disableBackground, argument: Data()) { _, ok in XCTAssertTrue(ok) }
        XCTAssertFalse(keepAlive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(tap.running, "Disabling background mode leaves capture running while the App is open")
        restarted.detach()
        XCTAssertFalse(tap.running)
        XCTAssertFalse(device.running)
        try press(2, on: tap)
        restarted.finish()
        trackpad.finish()
        let stored = try XCTUnwrap(defaults.data(forKey: "dailyStats"))
        XCTAssertEqual(try JSONDecoder().decode(DailyStats.self, from: stored).keyPresses, 4)
    }

    func testTrackpadRecorderWorksWithoutStudioOrPreview() throws {
        let session = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: session))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(session)
        defer {
            defaults.removePersistentDomain(forName: session)
            try? FileManager.default.removeItem(at: directory)
        }
        let device = SyntheticTrackpadCapture()
        let key = SymmetricKey(size: .bits256)
        let recorder = TrackpadRecording(capture: device, defaults: defaults, directory: directory,
                                         keyProvider: { _ in key }, uptime: { 10 })
        recorder.updateCapture()
        XCTAssertFalse(device.running)
        recorder.setRecording(true)
        XCTAssertTrue(device.running)
        XCTAssertFalse(recorder.preview)
        let contact = TrackpadContact(identity: 2, state: 4, sourceTime: 11,
                                     position: CGPoint(x: 0.25, y: 0.75), rawPressure: 20)
        device.emit(TrackpadFrame(sourceTime: 9, ordinal: 1, contacts: [contact]), receivedAt: 9)
        device.emit(TrackpadFrame(sourceTime: 11, ordinal: 2, contacts: [contact]), receivedAt: 11)
        recorder.setRecording(false)
        XCTAssertFalse(device.running)
        XCTAssertFalse(recorder.failed)

        let loaded = expectation(description: "Read the encrypted recording back")
        recorder.load(day: Date()) { reader in
            guard let reader else { XCTFail("Missing replay"); loaded.fulfill(); return }
            reader.take(through: 10) { frames, done, failed in
                XCTAssertTrue(done)
                XCTAssertFalse(failed)
                let contacts = frames.flatMap(\.contacts)
                XCTAssertEqual(contacts.count, 1)
                XCTAssertEqual(contacts.first?.position, contact.position)
                XCTAssertEqual(frames.last?.ordinal, 2)
                loaded.fulfill()
            }
        }
        wait(for: [loaded], timeout: 3)
    }

    func testIdleExitWaitsForBothConnectionAndBackgroundRecorder() {
        let exited = DispatchSemaphore(value: 0)
        let timeout = 0.15
        let supervisor = HelperIdleSupervisor(idleTimeout: timeout) { exited.signal() }
        supervisor.connectionDidOpen()
        supervisor.setBackgroundWorkActive(true)
        supervisor.connectionDidClose()
        let disconnected = exited.wait(timeout: .now() + timeout * 2)
        XCTAssertEqual(disconnected, .timedOut)
        guard disconnected == .timedOut else { return }

        supervisor.setBackgroundWorkActive(false)
        XCTAssertEqual(exited.wait(timeout: .now() + 2), .success)
        withExtendedLifetime(supervisor) {}
    }

    private let baseFields: Set<String> = [
        HelperPayloadFields.type,
        HelperPayloadFields.monotonicTime,
        HelperPayloadFields.sourcePID
    ]

    func testKeyboardPayloadContainsCodesAndFlagsWithoutText() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        event.flags = [.maskShift, .maskCommand]
        let syntheticText: [UniChar] = [0x61, 0x62]
        syntheticText.withUnsafeBufferPointer { buffer in
            event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
        }
        let payload = try XCTUnwrap(PayloadBuilder.build(from: event, type: .keyDown))
        XCTAssertEqual(Set(payload.keys), baseFields.union([
            HelperPayloadFields.keyCode, HelperPayloadFields.keyboardType,
            HelperPayloadFields.flags, HelperPayloadFields.isAutoRepeat
        ]))
        XCTAssertEqual((payload[HelperPayloadFields.keyCode] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((payload[HelperPayloadFields.flags] as? NSNumber)?.uint64Value, event.flags.rawValue)
        XCTAssertTrue(payload.values.allSatisfy { $0 is NSNumber })
    }

    func testReplayMetadataIsOptInAndUsesSourceTimestamp() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        event.timestamp = 123_456_789
        let off = try XCTUnwrap(PayloadBuilder.build(from: event, type: .keyDown))
        XCTAssertNil(off[HelperPayloadFields.replayTimestamp])
        XCTAssertNil(PayloadBuilder.build(from: event, type: .keyUp))
        let down = try XCTUnwrap(PayloadBuilder.build(from: event, type: .keyDown, recordsReplay: true))
        XCTAssertEqual((down[HelperPayloadFields.replayTimestamp] as? NSNumber)?.uint64Value, 123_456_789)
        XCTAssertEqual(down[HelperPayloadFields.replayPhase] as? String, "down")
        let up = try XCTUnwrap(PayloadBuilder.build(from: event, type: .keyUp, recordsReplay: true))
        XCTAssertEqual(up[HelperPayloadFields.replayPhase] as? String, "up")
        XCTAssertEqual(Set(up.keys), baseFields.union([HelperPayloadFields.keyCode,
            HelperPayloadFields.keyboardType, HelperPayloadFields.flags, HelperPayloadFields.isAutoRepeat,
            HelperPayloadFields.replayTimestamp, HelperPayloadFields.replayPhase]))
    }

    func testModifierPayloadRetainsTheKeyboardWireShape() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true))
        let payload = try XCTUnwrap(PayloadBuilder.build(from: event, type: .flagsChanged))
        XCTAssertEqual((payload[HelperPayloadFields.type] as? NSNumber)?.uint32Value, CGEventType.flagsChanged.rawValue)
        XCTAssertEqual((payload[HelperPayloadFields.keyCode] as? NSNumber)?.intValue, 56)
        XCTAssertNil(payload[HelperPayloadFields.locationX])
        XCTAssertNil(payload[HelperPayloadFields.locationY])
    }

    func testSideButtonPayloadDoesNotIncludeClickCoordinates() throws {
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                                         mouseCursorPosition: CGPoint(x: 12, y: 34), mouseButton: .center))
        for (number, role) in [(3, ButtonRole.back), (4, ButtonRole.forward)] {
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(number))
            let payload = try XCTUnwrap(PayloadBuilder.build(from: event, type: .otherMouseDown))
            XCTAssertEqual(Set(payload.keys), baseFields.union([
                HelperPayloadFields.buttonRole, HelperPayloadFields.buttonNumber
            ]))
            XCTAssertEqual(payload[HelperPayloadFields.buttonRole] as? String, role)
        }
    }

    func testMovementCoordinatesStayInTheExistingTransientPayload() throws {
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                         mouseCursorPosition: CGPoint(x: 12, y: 34), mouseButton: .left))
        let payload = try XCTUnwrap(PayloadBuilder.build(from: event, type: .mouseMoved))
        XCTAssertEqual(Set(payload.keys), baseFields.union([
            HelperPayloadFields.locationX, HelperPayloadFields.locationY
        ]))
        XCTAssertEqual((payload[HelperPayloadFields.locationX] as? NSNumber)?.doubleValue, 12)
        XCTAssertEqual((payload[HelperPayloadFields.locationY] as? NSNumber)?.doubleValue, 34)
    }

    func testScrollPayloadRetainsSessionMetadataWithoutCoordinates() throws {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                         wheelCount: 2, wheel1: 12, wheel2: -4, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let payload = try XCTUnwrap(PayloadBuilder.build(from: event, type: .scrollWheel))
        XCTAssertEqual(Set(payload.keys), baseFields.union([
            HelperPayloadFields.scrollDX, HelperPayloadFields.scrollDY,
            HelperPayloadFields.scrollPhase, HelperPayloadFields.scrollMomentumPhase,
            HelperPayloadFields.scrollIsContinuous
        ]))
        XCTAssertEqual((payload[HelperPayloadFields.scrollPhase] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((payload[HelperPayloadFields.scrollIsContinuous] as? NSNumber)?.boolValue, true)
    }

    func testMediaPayloadAcceptsOnlyAValidatedPress() throws {
        for (state, isRepeat, shouldForward) in [(NX_KEYDOWN, 0, true), (NX_KEYUP, 0, false), (NX_KEYDOWN, 1, false)] {
            let data = (Int(NX_KEYTYPE_SOUND_UP) << 16) | (Int(state) << 8) | isRepeat
            let event = try XCTUnwrap(NSEvent.otherEvent(with: .systemDefined, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS), data1: data, data2: -1)?.cgEvent)
            let payload = PayloadBuilder.build(from: event, type: SystemMediaKey.eventType)
            XCTAssertEqual(payload != nil, shouldForward)
            if let payload {
                XCTAssertEqual(Set(payload.keys), Set([
                    HelperPayloadFields.type, HelperPayloadFields.mediaKeyCode, HelperPayloadFields.flags
                ]))
                XCTAssertEqual(SystemMediaKey.keyName(from: payload), "VolumeUp")
            }
        }
    }

    func testUnsupportedEventsAreNotForwarded() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false))
        XCTAssertNil(PayloadBuilder.build(from: event, type: .keyUp))
        XCTAssertNil(PayloadBuilder.build(from: event, type: .leftMouseUp))
    }

    func testPackageUsesTheConfiguredServiceIdentityAndExistingXPCInterfaces() {
        XCTAssertEqual(HelperLocations.interfaceVersion, 4)
        #if DEBUG
        XCTAssertEqual(HelperLocations.mainBundleId, "com.xuanlprk.KeyTide.debug")
        XCTAssertEqual(HelperLocations.helperBundleId, "com.xuanlprk.KeyTide.debug.helper")
        let supportFolder = "Keytide Debug"
        #else
        XCTAssertEqual(HelperLocations.mainBundleId, "com.xuanlprk.KeyTide")
        XCTAssertEqual(HelperLocations.helperBundleId, "com.xuanlprk.KeyTide.helper")
        let supportFolder = "Keytide"
        #endif
        XCTAssertEqual(HelperLocations.machServiceName, HelperLocations.helperBundleId)
        XCTAssertEqual(HelperLocations.launchAgentLabel, HelperLocations.helperBundleId)
        XCTAssertEqual(HelperLocations.applicationSupportDirectory.lastPathComponent, supportFolder)
        XCTAssertEqual(HelperLocations.launchAgentPlistURL.lastPathComponent, HelperLocations.helperBundleId + ".plist")
        XCTAssertEqual(KeyReplayVault.directory.deletingLastPathComponent(), HelperLocations.applicationSupportDirectory)
        XCTAssertEqual(TrackpadReplayLibrary.directory.deletingLastPathComponent(), HelperLocations.applicationSupportDirectory)
        XCTAssertNotNil(NSXPCInterface(with: KeytideHelperProtocol.self))
        XCTAssertNotNil(NSXPCInterface(with: KeytideEventSinkProtocol.self))
    }
}
