import Cocoa
import XCTest
import QuartzCore
import Metal
import CryptoKit
import IOKit.hidsystem
@testable import KeytideCore

private final class StaticRenderScheduler {
    var actions: [() -> Void] = []
    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> (() -> Void) {
        XCTAssertEqual(delay, 0.08)
        actions.append(action)
        // Deliberately keep cancelled work executable to test the generation guard.
        return {}
    }
    func fireAll() { let pending = actions; actions = []; pending.forEach { $0() } }
}

final class GrowthKeyboard3DTests: XCTestCase {
    func testStreamingReplayCompletesAndReleasesReader() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Requires Metal") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeyReplayStore(directory: directory, key: SymmetricKey(size: .bits256))
        let events: [KeyReplayEvent] = [
            .init(milliseconds: 0, ordinal: 0, keyCode: 0, phase: .down, growthKeys: ["A"]),
            .init(milliseconds: 30, ordinal: 1, keyCode: 0, phase: .up, growthKeys: [])]
        try store.append(.init(version: 1, session: UUID(), startedAt: Date(), events: events), day: "2026-11-17")
        let reader = try store.makeReader(day: "2026-11-17")
        let ready = expectation(description: "Stream ready")
        var prepared: GrowthReplayPressPlan?
        reader.prepare { result in prepared = try? result.get(); ready.fulfill() }
        wait(for: [ready], timeout: 5)
        let plan = try XCTUnwrap(prepared)
        let baseline = layout(), scene = GrowthKeyboard3DScene(layout())
        let surface = GrowthReplayPressSurface(scene: GrowthReplayPressScene(mac: scene),
            size: GrowthKeyboard3DScene.size, supported: Set(baseline.keys.map(\.id)))
        let from = baseline.keys.map { GrowthKeyboardKeyUsage(id: $0.id, count: 0) }
        let to = baseline.keys.map { GrowthKeyboardKeyUsage(id: $0.id, count: $0.id == "A" ? 1 : 0) }
        var count = 0
        surface.onProgress = { _, events in count = events }
        surface.onFailure = { XCTFail("Valid streaming replay failed") }
        let finished = expectation(description: "Stream presented")
        surface.play(plan, values: from, target: to, background: .clear) { finished.fulfill() }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(count, 1)
        XCTAssertFalse(surface.isAnimating)
        XCTAssertTrue(reader.cancellation.isCancelled)
        let retained = Mirror(reflecting: surface).children.first { $0.label == "plan" }!.value as! GrowthReplayPressPlan
        XCTAssertNil(retained.stream)
        // Appearance/resolution changes can cancel an in-flight stream before
        // its final image is presented. The cancelled reader must not be reused.
        let scheduler = StaticRenderScheduler()
        let renderer = GrowthKeyboard3DRenderer(layout: baseline, renderFrame: { _, _ in
            GrowthKeyboard3DFrame(image: NSImage(size: GrowthKeyboard3DScene.size), rects: [:])
        }, replayPress: { _, _, _, _ in XCTFail("Cancelled stream restarted"); return {} },
            reduceMotion: { false }, schedule: scheduler.schedule)
        renderer.setActive(true)
        var presented = false
        renderer.apply(to, animated: true, replayFrom: from, recordedReplay: plan) { presented = true }
        scheduler.fireAll()
        XCTAssertTrue(presented)
        XCTAssertFalse(renderer.isReplayingPress)
    }

    func testFrameCacheHonorsByteBudgetAndStillPresentsOversizedFrames() {
        let scheduler = StaticRenderScheduler()
        let view = GrowthKeyboard3DRenderer(layout: layout(), renderFrame: { _, _ in
            GrowthKeyboard3DFrame(image: NSImage(size: CGSize(width: 10, height: 10)), rects: [:])
        }, imageSize: CGSize(width: 10, height: 10), cacheByteLimit: 3200, schedule: scheduler.schedule)
        view.setActive(true)
        for count in 1...4 {
            view.apply([.init(id: "A", count: count)]); scheduler.fireAll()
            XCTAssertLessThanOrEqual(view.cachedByteCount, 3200)
            XCTAssertLessThanOrEqual(view.cachedFrameCount, 2)
        }
        XCTAssertEqual(view.cachedFrameCount, 2)
        view.apply([.init(id: "A", count: 3)]); scheduler.fireAll()
        XCTAssertEqual(view.renderCount, 4, "Recent frame survives LRU eviction")
        view.apply([.init(id: "A", count: 1)]); scheduler.fireAll()
        XCTAssertEqual(view.renderCount, 5, "Old frame was evicted by bytes before the count limit")
        let oversized = GrowthKeyboard3DRenderer(layout: layout(), renderFrame: { _, _ in
            GrowthKeyboard3DFrame(image: NSImage(size: CGSize(width: 10, height: 10)), rects: [:])
        }, imageSize: CGSize(width: 10, height: 10), cacheByteLimit: 1, schedule: scheduler.schedule)
        oversized.setActive(true)
        var presented = false
        oversized.apply([.init(id: "A", count: 1)]) { presented = true }
        scheduler.fireAll()
        XCTAssertTrue(presented)
        XCTAssertNotNil(oversized.displayedFrame)
        XCTAssertEqual(oversized.cachedFrameCount, 0)
        XCTAssertEqual(oversized.cachedByteCount, 0)
    }

    func testReplayReleasesEventsOnCancelAndBeforeCompletion() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Requires Metal") }
        let baseline = layout()
        let model = GrowthKeyboard3DScene(baseline)
        let surface = GrowthReplayPressSurface(scene: GrowthReplayPressScene(mac: model),
            size: GrowthKeyboard3DScene.size, supported: Set(baseline.keys.map(\.id)))
        let values = baseline.keys.map { GrowthKeyboardKeyUsage(id: $0.id, count: 0) }
        func retainedCount() -> Int {
            let plan = Mirror(reflecting: surface).children.first { $0.label == "plan" }!.value as! GrowthReplayPressPlan
            return plan.entries.count
        }
        let entries: [KeyReplayDay.Entry] = (0..<1000).map { i in
            let event = KeyReplayEvent(milliseconds: UInt64(i * 100), ordinal: UInt64(i),
                keyCode: 0, phase: .up, growthKeys: [])
            return .init(seconds: Double(i) / 10, event: event, startsSession: i == 0)
        }
        var completed = false
        surface.play(GrowthReplayPressPlan(day: .init(entries: entries, hasUnreadableChunks: false)),
            values: values, target: values, background: .clear) { completed = true }
        XCTAssertEqual(retainedCount(), 1000)
        surface.cancel()
        XCTAssertEqual(retainedCount(), 0)
        XCTAssertFalse(completed)
        surface.play(GrowthReplayPressPlan(day: .init(entries: [entries[0]], hasUnreadableChunks: false)),
            values: values, target: values, background: .clear) {
                XCTAssertEqual(retainedCount(), 0)
                completed = true
            }
        XCTAssertTrue(completed)
        XCTAssertFalse(surface.isAnimating)
    }

    func testTypingModifiersIgnoreCrossSideReleasesAndHandleCapsLockOff() {
        let pairs: [(UInt16, UInt16, UInt, UInt, NSEvent.ModifierFlags)] = [
            (56, 60, UInt(NX_DEVICELSHIFTKEYMASK), UInt(NX_DEVICERSHIFTKEYMASK), .shift),
            (55, 54, UInt(NX_DEVICELCMDKEYMASK), UInt(NX_DEVICERCMDKEYMASK), .command),
            (58, 61, UInt(NX_DEVICELALTKEYMASK), UInt(NX_DEVICERALTKEYMASK), .option),
            (59, 62, UInt(NX_DEVICELCTLKEYMASK), UInt(NX_DEVICERCTLKEYMASK), .control)]
        for (left, right, leftMask, rightMask, family) in pairs {
            let both = NSEvent.ModifierFlags(rawValue: family.rawValue | leftMask | rightMask)
            XCTAssertEqual(MechanicalKeyboardView.modifierPressKeyID(left, flags: both), MechanicalKeyboardView.physicalKeyID(left))
            XCTAssertEqual(MechanicalKeyboardView.modifierPressKeyID(right, flags: both), MechanicalKeyboardView.physicalKeyID(right))
            XCTAssertNil(MechanicalKeyboardView.modifierPressKeyID(left,
                flags: NSEvent.ModifierFlags(rawValue: family.rawValue | rightMask)))
            XCTAssertNil(MechanicalKeyboardView.modifierPressKeyID(right,
                flags: NSEvent.ModifierFlags(rawValue: family.rawValue | leftMask)))
        }
        XCTAssertEqual(MechanicalKeyboardView.modifierPressKeyID(57, flags: .capsLock), "CapsLock")
        XCTAssertEqual(MechanicalKeyboardView.modifierPressKeyID(57, flags: []), "CapsLock")
        XCTAssertEqual(MechanicalKeyboardView.modifierPressKeyID(63, flags: .function), "Fn")
        XCTAssertNil(MechanicalKeyboardView.modifierPressKeyID(63, flags: []))
    }

    func testViewportPreservesAnchorAndClampsZoomAndPan() {
        var viewport = KeyboardViewportState()
        let size = CGSize(width: 1000, height: 600), anchor = CGPoint(x: 300, y: 240)
        viewport.zoom(by: 2, at: anchor, in: size)
        let frame = viewport.frame(in: size)
        XCTAssertEqual((anchor.x - frame.minX) / frame.width, 0.3, accuracy: 0.000_001)
        XCTAssertEqual((anchor.y - frame.minY) / frame.height, 0.4, accuracy: 0.000_001)
        viewport.pan(by: CGSize(width: 100000, height: -100000), in: size)
        XCTAssertEqual(viewport.frame(in: size).minX, 0)
        XCTAssertEqual(viewport.frame(in: size).maxY, size.height)
        viewport.zoom(by: 100, at: anchor, in: size)
        XCTAssertEqual(viewport.scale, 2.5)
        viewport.zoom(by: 0.001, at: anchor, in: size)
        XCTAssertEqual(viewport.scale, 0.75)
        XCTAssertEqual(viewport.offset, .zero)
        viewport.zoom(by: .nan, at: anchor, in: size)
        XCTAssertEqual(viewport.scale, 0.75)
        viewport.reset()
        XCTAssertEqual(viewport.frame(in: size), CGRect(origin: .zero, size: size))
    }

    func testEveryLegendFitsTopWithoutOverlapsAndLettersStayCentered() {
        let layout = layout()
        for key in layout.keys {
            for scale in [0.75, 1.0, 2.5] {
                let top = CGRect(x: 20, y: 30, width: key.size.width * scale * 0.6,
                    height: key.size.height * scale * 0.6)
                let marks = KeyboardLegendLayout.marks(for: key, top: top)
                if key.id != "Space" { XCTAssertFalse(marks.isEmpty, key.id) }
                for (index, mark) in marks.enumerated() {
                    XCTAssertTrue(top.insetBy(dx: -0.001, dy: -0.001).contains(mark.rect), key.id)
                    // The approved centered legends use the full top surface;
                    // the old 78% strip rule predates that layout change.
                    if key.id.count == 1, key.id.first?.isLetter == true, marks.count == 1 {
                        XCTAssertEqual(mark.rect.midX, top.midX, accuracy: 0.001, key.id)
                        XCTAssertEqual(mark.rect.midY, top.midY, accuracy: 0.001, key.id)
                    }
                    for other in marks.dropFirst(index + 1) {
                        XCTAssertFalse(mark.rect.intersects(other.rect), "Overlapping marks on \(key.id)")
                    }
                }
            }
        }
    }

    func testMacTopProjectionFollowsPressWithoutChangingOtherKeys() throws {
        let layout = layout(), scene = GrowthKeyboard3DScene(layout)
        let values = layout.keys.map { GrowthKeyboardKeyUsage(id: $0.id, count: 300) }
        let rest = scene.render(values: values, backgroundColor: .clear, pixelScale: 1)
        let pressed = scene.render(values: values, backgroundColor: .clear, pressOffsets: ["S": 0.1], pixelScale: 1)
        let release = scene.render(values: values, backgroundColor: .clear, pixelScale: 1)
        let top = try XCTUnwrap(rest.rects["S"])
        XCTAssertNotEqual(top, pressed.rects["S"])
        XCTAssertEqual(top, release.rects["S"])
        XCTAssertEqual(rest.rects["A"], pressed.rects["A"])
        XCTAssertEqual(rest.rects.count, 77)
    }

    func testResolutionRefinementWaitsForReplayAndKeepsThreeFrameCache() {
        let layout = layout(), scheduler = StaticRenderScheduler()
        var finish: (() -> Void)?, cancellations = 0
        var resolutions: [CGFloat] = []
        let frame = fakeFrame(layout)
        let view = GrowthKeyboard3DRenderer(layout: layout,
            renderDetailedFrame: { _, _, scale in resolutions.append(scale); return frame },
            replayPress: { _, _, _, completion in finish = completion; return { cancellations += 1 } },
            reduceMotion: { false }, schedule: scheduler.schedule)
        view.setActive(true)
        let values = layout.keys.map { GrowthKeyboardKeyUsage(id: $0.id, count: 1) }
        view.apply(values, animated: true, replayFrom: values,
            recordedReplay: GrowthReplayPressPlan(day: KeyReplayExample.make().day))
        scheduler.fireAll()
        XCTAssertTrue(view.isReplayingPress)
        view.setFrameSize(CGSize(width: 3200, height: 1500))
        view.updateDisplayResolution()
        XCTAssertEqual(cancellations, 0)
        XCTAssertFalse(view.hasScheduledRender)
        finish?()
        scheduler.fireAll()
        XCTAssertEqual(resolutions, [2, 5])
        XCTAssertFalse(view.isReplayingPress)
        XCTAssertLessThanOrEqual(view.cachedFrameCount, 3)
    }

    func testMacReplayPressIsStrongerAndThinCapsStayAboveDeck() throws {
        XCTAssertEqual(GrowthKeyboard3DScene.pressTravel(offset: MechanicalPressProfile.light.travel, height: 0.30), 0.10, accuracy: 0.000_001)
        for height in [GrowthKeyboard3DGeometry.minimumHeight, 0.03, 0.10, 0.30, GrowthKeyboard3DGeometry.maximumHeight] {
            for offset in [-1.0, 0, 0.04, 0.10, 1] {
                let travel = GrowthKeyboard3DScene.pressTravel(offset: CGFloat(offset), height: height)
                XCTAssertGreaterThanOrEqual(travel, 0)
                XCTAssertGreaterThanOrEqual(height - travel, height * 0.45 - 0.000_001)
            }
        }
        let base = NSColor(srgbRed: 0.8, green: 0.85, blue: 0.9, alpha: 1)
        let pressed = try XCTUnwrap(GrowthKeyboard3DScene.pressColor(base, offset: 0.10).usingColorSpace(.sRGB))
        XCTAssertLessThan(pressed.redComponent, 0.72)
        XCTAssertEqual(pressed.alphaComponent, 1, accuracy: 0.000_001)
        XCTAssertEqual(GrowthKeyboard3DScene.pressColor(base, offset: 0), base, "Release restores the exact resting color")
    }

    func testExportUsesPresentedFrameWithoutChangingSelectionOrRendering() throws {
        let layout = layout(), scheduler = StaticRenderScheduler()
        let view = GrowthKeyboard3DRenderer(layout: layout,
            renderFrame: { _, _ in self.fakeFrame(layout) }, schedule: scheduler.schedule)
        XCTAssertNil(view.exportImage())
        view.setActive(true)
        view.apply([.init(id: "A", count: 1)])
        scheduler.fireAll()
        let baseline = try XCTUnwrap(view.exportImage()?.tiffRepresentation)
        view.selectKey("A")
        view.apply([.init(id: "A", count: 999)])
        let selected = try XCTUnwrap(view.exportImage()?.tiffRepresentation)
        XCTAssertEqual(baseline, selected, "Selection overlays and unpresented counts must not enter exports")
        XCTAssertEqual(view.selectedKeyID, "A")
        XCTAssertEqual(view.renderCount, 1)
        XCTAssertTrue(view.hasScheduledRender)
    }

    func testExportBitmapHasExplicitResolutionAndTopDownCoordinates() throws {
        let bitmap = try XCTUnwrap(KeyboardImageBitmap.make(size: CGSize(width: 20, height: 10)) {
            NSColor.red.setFill()
            CGRect(x: 0, y: 0, width: 10, height: 5).fill()
        })
        XCTAssertEqual(bitmap.pixelsWide, 40)
        XCTAssertEqual(bitmap.pixelsHigh, 20)
        let top = try XCTUnwrap(bitmap.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(top.redComponent, 0.9)
        XCTAssertGreaterThan(top.alphaComponent, 0.9)
        XCTAssertEqual(bitmap.colorAt(x: 30, y: 15)?.alphaComponent, 0)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertNotNil(NSBitmapImageRep(data: png))
    }

    func testDeactivationRemovesCoreAnimationReservedTransitionAndPendingFrame() {
        let layout = layout(), scheduler = StaticRenderScheduler()
        let view = GrowthKeyboard3DRenderer(layout: layout,
            renderFrame: { _, _ in self.fakeFrame(layout) }, schedule: scheduler.schedule)
        view.setActive(true)
        view.apply([.init(id: "A", count: 1)])
        scheduler.fireAll()
        let transition = CATransition()
        transition.duration = 10
        view.layer?.add(transition, forKey: "growthReplayFrame")
        XCTAssertNotNil(view.layer?.animation(forKey: kCATransition))
        view.apply([.init(id: "A", count: 2)])
        XCTAssertTrue(view.hasScheduledRender)
        view.setActive(false)
        XCTAssertNil(view.layer?.animation(forKey: kCATransition))
        XCTAssertFalse(view.hasScheduledRender)
        scheduler.fireAll()
        XCTAssertEqual(view.renderCount, 1)
    }

    func test3DReplayWaitsForEachRenderedDayReusesGapsAndStopsAtToday() throws {
        for mechanical in [false, true] {
            let layout = layout(), renderScheduler = StaticRenderScheduler()
            let model: MechanicalKeyboardScene?
            if mechanical {
                model = try MechanicalKeyboardScene()
                try model!.configureFullModel()
            } else { model = nil }
            let imageSize = mechanical ? MechanicalKeyboardScene.size : GrowthKeyboard3DScene.size
            var steps: [() -> Void] = []
            let driver = GrowthPlaybackDriver(schedule: { delay, action in
                XCTAssertEqual(delay, 0.35); steps.append(action); return {}
            })
            driver.waitsForPresentation = true; driver.stepInterval = 0.35
            driver.reset(dayCount: 4)
            let view = GrowthKeyboard3DRenderer(layout: layout, renderFrame: { values, _ in
                if let model {
                    model.applyGrowth(values)
                    let usage = values.first { $0.id == "A" }!
                    XCTAssertEqual(model.growthHeights.count, 77)
                    XCTAssertEqual(model.growthHeights["A"], MechanicalKeyboardScene.growthHeight(usage.progress))
                    let node = model.fullModelNodes.first { $0.name == "A" }!
                    XCTAssertEqual(node.geometry?.firstMaterial?.diffuse.contents as? NSColor,
                                   model.baseline.usageColor(usage.progress))
                }
                return GrowthKeyboard3DFrame(image: NSImage(size: imageSize),
                    rects: Dictionary(uniqueKeysWithValues: layout.keys.map { ($0.id, $0.rect) }))
            }, imageSize: imageSize, bakesLegends: mechanical, schedule: renderScheduler.schedule)
            var observed: [Int] = []
            var displayed: [Int] = []
            let counts = [1, 1, 20, 100]
            driver.onChange = { offset in
                observed.append(offset)
                let token = driver.presentationGeneration
                view.apply([.init(id: "A", count: counts[offset])], animated: driver.isPresentingPlaybackFrame) {
                    displayed.append(offset)
                    driver.framePresented(at: offset, generation: token)
                }
            }
            view.setActive(true); driver.setActive(true); driver.start()
            XCTAssertEqual(observed, [0])
            XCTAssertTrue(steps.isEmpty) // A cold render cannot be skipped by a calendar timer.
            renderScheduler.fireAll()
            XCTAssertEqual(displayed, [0]); XCTAssertEqual(steps.count, 1)
            steps[0]() // A missing date holds identical cumulative values.
            XCTAssertEqual(displayed, [0, 1]); XCTAssertEqual(view.renderCount, 1)
            XCTAssertEqual(steps.count, 2)
            steps[1]()
            XCTAssertEqual(observed, [0, 1, 2]); XCTAssertEqual(displayed, [0, 1])
            XCTAssertNotNil(view.displayedFrame) // Keep the previous image during replay rendering.
            XCTAssertEqual(steps.count, 2)
            renderScheduler.fireAll()
            XCTAssertEqual(displayed, [0, 1, 2]); XCTAssertEqual(steps.count, 3)
            steps[2](); renderScheduler.fireAll()
            XCTAssertEqual(displayed, [0, 1, 2, 3])
            XCTAssertEqual(view.renderCount, 3)
            XCTAssertEqual(view.cachedFrameCount, 3)
            XCTAssertFalse(driver.state.isPlaying)
            XCTAssertFalse(driver.hasScheduledStep)
            XCTAssertEqual(steps.count, 3)
        }
    }

    func test3DReplayRejectsDuplicateAndStalePresentationAcknowledgements() {
        var steps: [() -> Void] = []
        let driver = GrowthPlaybackDriver(schedule: { _, action in steps.append(action); return {} })
        driver.waitsForPresentation = true; driver.reset(dayCount: 3); driver.setActive(true); driver.start()
        let old = driver.presentationGeneration
        driver.framePresented(at: 1, generation: old)
        XCTAssertTrue(steps.isEmpty)
        driver.pause()
        driver.framePresented(at: 0, generation: old)
        XCTAssertTrue(steps.isEmpty)
        driver.start()
        driver.framePresented(at: 0, generation: old)
        XCTAssertTrue(steps.isEmpty)
        let current = driver.presentationGeneration
        driver.framePresented(at: 0, generation: current)
        driver.framePresented(at: 0, generation: current)
        XCTAssertEqual(steps.count, 1)
        driver.setActive(false); steps[0]()
        XCTAssertEqual(driver.state.offset, 0)
        XCTAssertFalse(driver.state.isPlaying)
    }

    func testReturningToDisplayedDateCancelsPendingReplayFrame() {
        let layout = layout(), scheduler = StaticRenderScheduler()
        let view = GrowthKeyboard3DRenderer(layout: layout, renderFrame: { _, _ in self.fakeFrame(layout) }, schedule: scheduler.schedule)
        view.setActive(true)
        view.apply([.init(id: "A", count: 1)]); scheduler.fireAll()
        var presented: [Int] = []
        view.apply([.init(id: "A", count: 2)], animated: true) { presented.append(2) }
        view.apply([.init(id: "A", count: 1)], animated: true) { presented.append(1) }
        scheduler.fireAll()
        XCTAssertEqual(presented, [1])
        XCTAssertEqual(view.renderCount, 1)
    }

    func testReplayCountsStayWithDisplayedImageUntilNextFrameIsReady() {
        let layout = layout(), scheduler = StaticRenderScheduler()
        let view = GrowthKeyboard3DRenderer(layout: layout, renderFrame: { _, _ in self.fakeFrame(layout) }, schedule: scheduler.schedule)
        view.setActive(true)
        view.apply([.init(id: "A", count: 1)]); scheduler.fireAll()
        var selected: GrowthKeyboardKeyUsage?
        view.onSelectionChanged = { selected = $0 }; view.selectKey("A")
        view.apply([.init(id: "A", count: 2)], animated: true)
        XCTAssertEqual(selected?.count, 1)
        scheduler.fireAll()
        XCTAssertEqual(selected?.count, 2)
        XCTAssertEqual(view.renderCount, 2)
    }

    func testProductionPageSwitchesModesKeepsDateSelectionAndEnables3DReplay() throws {
        let calendar = Calendar.current
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let first = formatter.date(from: "2026-10-01")!, now = formatter.date(from: "2026-10-03")!
        let suite = "KeyStatsTests.3DPage." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var past = DailyStats(date: first); past.keyPresses = 3; past.keyPressCounts = ["A": 3]
        var today = DailyStats(date: now); today.keyPresses = 7; today.keyPressCounts = ["A": 7]
        defaults.set(try JSONEncoder().encode(["2026-10-01": past]), forKey: "dailyStatsHistory")
        defaults.set(try JSONEncoder().encode(today), forKey: "dailyStats")
        let manager = StatsManager(environment: .init(userDefaults: defaults, now: { now }, calendar: { calendar },
            makeDateKeyFormatter: { formatter.copy() as! DateFormatter }, notificationCenter: NotificationCenter(),
            schedulesAutomaticWork: false,
            sendThresholdNotification: { _, _, _ in }))
        let page = GrowthKeyboardViewController(manager: manager)
        page.refreshData(resetToToday: true)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(page.view)
        let selector = try XCTUnwrap(views.compactMap { $0 as? NSSegmentedControl }.first)
        let play = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("togglePlayback") })
        XCTAssertEqual(selector.selectedSegment, 0)
        XCTAssertTrue(play.isEnabled)
        selector.selectedSegment = 1
        page.perform(selector.action!)
        XCTAssertTrue(play.isEnabled)
        let spatial = try XCTUnwrap(descendants(page.view).compactMap { $0 as? GrowthKeyboard3DRenderer }.first)
        XCTAssertFalse(spatial.hasScheduledRender) // No window: mode/date changes must not start SceneKit.
        var selected: GrowthKeyboardKeyUsage?
        spatial.onSelectionChanged = { selected = $0 }
        spatial.selectKey("A")
        // The production load uses today's actual date. Select this fixture's history explicitly.
        let picker = try XCTUnwrap(views.compactMap { $0 as? NSDatePicker }.first)
        picker.dateValue = first; page.perform(picker.action!)
        XCTAssertEqual(selected?.count, 3)
        picker.dateValue = now; page.perform(picker.action!)
        XCTAssertEqual(selected?.count, 10)
        selector.selectedSegment = 0; page.perform(selector.action!)
        XCTAssertTrue(play.isEnabled)
        XCTAssertTrue(spatial.isHidden)
        XCTAssertFalse(spatial.isActive)
        XCTAssertEqual(spatial.renderCount, 0)
        page.setMechanical(true)
        XCTAssertTrue(page.usesMechanical)
        XCTAssertTrue(play.isEnabled)
        let mechanical = try XCTUnwrap(descendants(page.view).compactMap { $0 as? GrowthKeyboard3DRenderer }.first)
        var mechanicalSelection: GrowthKeyboardKeyUsage?
        mechanical.onSelectionChanged = { mechanicalSelection = $0 }
        mechanical.selectKey("A")
        XCTAssertEqual(mechanicalSelection?.count, 10)
        picker.dateValue = first; page.perform(picker.action!)
        XCTAssertEqual(mechanicalSelection?.count, 3)
        XCTAssertFalse(mechanical.hasScheduledRender)
        weak var closedRenderer: GrowthKeyboard3DRenderer?
        autoreleasepool {
            page.setMechanical(false)
            XCTAssertFalse(page.usesMechanical)
            XCTAssertTrue(play.isEnabled)
            closedRenderer = descendants(page.view).compactMap { $0 as? GrowthKeyboard3DRenderer }.first
            page.setPresented(false)
            XCTAssertNotNil(closedRenderer, "Temporary inactivity retains the complete frame")
            page.releaseResourcesForClosedWindow()
        }
        XCTAssertNil(closedRenderer, "Closing releases the renderer, its scene and frame cache")
        page.setPresented(true)
        page.refreshData(resetToToday: true)
        let reopened = try XCTUnwrap(descendants(page.view).compactMap { $0 as? GrowthKeyboard3DRenderer }.first)
        XCTAssertFalse(reopened.hasScheduledRender, "An unattached page must not render")
        var reopenedSelection: GrowthKeyboardKeyUsage?
        reopened.onSelectionChanged = { reopenedSelection = $0 }
        reopened.selectKey("A")
        XCTAssertEqual(reopenedSelection?.count, 10)

        // A rebuilt page must still return from the example to the user's real day.
        page.showDay(first)
        page.showExample()
        page.releaseResourcesForClosedWindow()
        let rebuilt = GrowthKeyboardViewController(manager: manager)
        rebuilt.restoreBrowsing(page.browsingState)
        rebuilt.refreshData(resetToToday: true)
        XCTAssertEqual(rebuilt.browsingState.scope, 3)
        let back = try XCTUnwrap(descendants(rebuilt.view).compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("showToday") })
        rebuilt.perform(try XCTUnwrap(back.action))
        XCTAssertEqual(rebuilt.browsingState.scope, 1)
        XCTAssertEqual(rebuilt.browsingState.inspectionDate, first)
    }

    func testMechanicalGrowthHeightIsFixedBoundedAndMonotonic() {
        var previous: CGFloat = 0
        for index in 0...1000 {
            let height = MechanicalKeyboardScene.growthHeight(Double(index) / 1000)
            XCTAssertGreaterThanOrEqual(height, previous)
            XCTAssertGreaterThanOrEqual(height, 0.35)
            XCTAssertLessThanOrEqual(height, 0.75)
            previous = height
        }
        XCTAssertEqual(MechanicalKeyboardScene.growthHeight(-1), 0.35)
        XCTAssertEqual(MechanicalKeyboardScene.growthHeight(2), 0.75)
    }

    func testMechanicalGrowthUsesFormalPaletteAndReusesUnchangedGeometry() throws {
        let model = try MechanicalKeyboardScene()
        try model.configureFullModel()
        let values = [GrowthKeyboardKeyUsage(id: "A", count: 10_000), .init(id: "Space", count: 1_000_000)]
        model.applyGrowth(values)
        let nodes = Dictionary(uniqueKeysWithValues: model.fullModelNodes.map { ($0.name!, $0) })
        let identities = model.fullModelNodes.map { ObjectIdentifier($0.geometry!) }
        XCTAssertEqual(model.growthHeights.count, 77)
        for value in values {
            XCTAssertEqual(model.growthHeights[value.id], MechanicalKeyboardScene.growthHeight(value.progress))
            let color = try XCTUnwrap(nodes[value.id]?.geometry?.firstMaterial?.diffuse.contents as? NSColor)
            XCTAssertEqual(color, model.baseline.usageColor(value.progress))
        }
        XCTAssertEqual(model.growthHeights["F1"], 0.35)
        model.applyGrowth(values + [.init(id: "S", count: 900_000)])
        XCTAssertEqual(ObjectIdentifier(nodes["A"]!.geometry!), identities[model.keys.firstIndex { $0.id == "A" }!])
        XCTAssertEqual(model.growthHeights["A"], MechanicalKeyboardScene.growthHeight(0.5))
        let updated = model.fullModelNodes.map { ObjectIdentifier($0.geometry!) }
        model.applyGrowth(values + [.init(id: "S", count: 900_000)])
        XCTAssertEqual(model.fullModelNodes.map { ObjectIdentifier($0.geometry!) }, updated)
    }

    private func layout() -> EditorialKeyboardSceneLayout {
        EditorialKeyboardRenderer(frame: .zero).sceneLayout
    }
    private func fakeFrame(_ layout: EditorialKeyboardSceneLayout) -> GrowthKeyboard3DFrame {
        GrowthKeyboard3DFrame(image: NSImage(size: GrowthKeyboard3DScene.size),
            rects: Dictionary(uniqueKeysWithValues: layout.keys.map { ($0.id, $0.rect) }))
    }
    private func assertSameRect(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1e-9, file: file, line: line)
    }

    func testGeometryV2RemainsBoundedMonotonicAndSeparateFromStatisticalProgress() {
        var previous: CGFloat = 0
        for index in 0...1000 {
            let p = Double(index) / 1000
            let formation = -expm1(-pow(p / 0.32, 1.6)) / -expm1(-pow(1 / 0.32, 1.6))
            let height = GrowthKeyboard3DGeometry.height(p)
            XCTAssertEqual(height, 0.012 + (0.476 - 0.012) * formation, accuracy: 1e-12)
            XCTAssertGreaterThanOrEqual(height, previous)
            XCTAssertLessThanOrEqual(height, 0.476)
            XCTAssertLessThan(GrowthKeyboard3DGeometry.bevel(p), height / 2)
            previous = height
        }
        XCTAssertEqual(GrowthKeyboard3DGeometry.height(0), 0.012)
        XCTAssertEqual(GrowthKeyboard3DGeometry.height(1), 0.476, accuracy: 1e-12)
        XCTAssertGreaterThan(GrowthKeyboard3DGeometry.formation(0.5), 0.85)
        XCTAssertEqual(GrowthKeyboardKeyUsage(id: "A", count: 10_000).progress, 0.5, accuracy: 1e-12)
    }

    func testExplicitSceneInterfaceMatchesApproved77KeyPrototypeInputsWithoutLayerIndexBridge() throws {
        let reference = EditorialKeyboardRenderer(frame: .zero)
        let layout = reference.sceneLayout
        XCTAssertEqual(layout.keys.map(\.id), KeyboardLayout.macStyle.keys.map(\.id))
        XCTAssertEqual(layout.keys.count, 77)
        let board = try XCTUnwrap(reference.layer?.sublayers?.first)
        XCTAssertEqual(layout.boardSize, board.bounds.size)
        for key in layout.keys {
            let cap = try XCTUnwrap(board.sublayers?.first { $0.name == key.id })
            let shapes = try XCTUnwrap(cap.sublayers).compactMap { $0 as? CAShapeLayer }
            let legend = try XCTUnwrap(cap.sublayers?.compactMap { $0 as? CATextLayer }.first)
            XCTAssertEqual(key.rect, cap.frame)
            XCTAssertEqual(key.size, cap.bounds.size)
            XCTAssertTrue(key.topPath === shapes[2].path)
            XCTAssertEqual(key.legend, legend.string as? NSAttributedString)
            assertSameRect(key.legendFrame, legend.frame)
            XCTAssertEqual(key.legendAlignment, legend.alignmentMode)
        }
        let rest = layout.keys.first { $0.id == "A" }!.legendFrame
        reference.selectKey("A")
        assertSameRect(reference.sceneLayout.keys.first { $0.id == "A" }!.legendFrame, rest)
    }

    func testHiddenViewNeverRendersAndCancelledDatesCannotRenderAfterHide() {
        let layout = layout(), scheduler = StaticRenderScheduler()
        var calls = 0
        let view = GrowthKeyboard3DRenderer(layout: layout, renderFrame: { _, _ in
            calls += 1; return self.fakeFrame(layout)
        }, schedule: scheduler.schedule)
        view.apply([.init(id: "A", count: 1)])
        XCTAssertFalse(view.hasScheduledRender)
        view.setActive(true)
        XCTAssertTrue(view.hasScheduledRender)
        view.setActive(false)
        scheduler.fireAll()
        XCTAssertEqual(calls, 0)
        view.apply([.init(id: "A", count: 2)])
        scheduler.fireAll()
        XCTAssertEqual(calls, 0)
        view.setActive(true); scheduler.fireAll()
        XCTAssertEqual(calls, 1)
    }

    func testReactivationPresentsLatestPendingSnapshotWithoutAcknowledgingWhileHidden() {
        let layout = layout(), scheduler = StaticRenderScheduler()
        var rendered: [Int] = [], presented: [Int] = []
        let view = GrowthKeyboard3DRenderer(layout: layout, renderFrame: { values, _ in
            rendered.append(values.first { $0.id == "A" }!.count)
            return self.fakeFrame(layout)
        }, schedule: scheduler.schedule)
        view.setActive(true)
        view.apply([.init(id: "A", count: 1)]) { presented.append(1) }
        view.setActive(false)
        scheduler.fireAll()
        XCTAssertTrue(rendered.isEmpty)
        XCTAssertTrue(presented.isEmpty)

        view.setActive(true)
        scheduler.fireAll()
        XCTAssertEqual(rendered, [1])
        XCTAssertEqual(presented, [1])

        view.apply([.init(id: "A", count: 2)]) { presented.append(2) }
        view.setActive(false)
        view.apply([.init(id: "A", count: 3)]) { presented.append(3) }
        view.setActive(false)
        scheduler.fireAll()
        XCTAssertEqual(presented, [1])
        view.setActive(true)
        scheduler.fireAll()
        view.setActive(true)
        XCTAssertEqual(rendered, [1, 3])
        XCTAssertEqual(presented, [1, 3])
    }

    func testDateChangesCoalesceAndThreeFrameCacheIncludesCountsAndAppearance() {
        let layout = layout(), scheduler = StaticRenderScheduler()
        var renderedCounts: [Int] = []
        let view = GrowthKeyboard3DRenderer(layout: layout, renderFrame: { values, _ in
            renderedCounts.append(values.first { $0.id == "A" }!.count)
            return self.fakeFrame(layout)
        }, schedule: scheduler.schedule)
        view.appearance = NSAppearance(named: .aqua)
        view.setActive(true)
        view.apply([.init(id: "A", count: 1)])
        view.apply([.init(id: "A", count: 2)])
        view.apply([.init(id: "A", count: 3)])
        scheduler.fireAll()
        XCTAssertEqual(renderedCounts, [3])
        for count in [1, 2] { view.apply([.init(id: "A", count: count)]); scheduler.fireAll() }
        XCTAssertEqual(view.cachedFrameCount, 3)
        view.apply([.init(id: "A", count: 3)]); scheduler.fireAll()
        XCTAssertEqual(renderedCounts, [3, 1, 2])
        view.apply([.init(id: "A", count: 4)]); scheduler.fireAll()
        XCTAssertEqual(view.cachedFrameCount, 3)
        view.apply([.init(id: "A", count: 1)]); scheduler.fireAll()
        XCTAssertEqual(renderedCounts, [3, 1, 2, 4, 1])
        view.appearance = NSAppearance(named: .darkAqua)
        view.viewDidChangeEffectiveAppearance(); scheduler.fireAll()
        XCTAssertEqual(renderedCounts.count, 6)
        XCTAssertEqual(view.cachedFrameCount, 3)
    }

    func testKeySelectionShowsExactCountsAcrossDatesWithoutSceneRender() {
        let layout = layout(), scheduler = StaticRenderScheduler()
        let view = GrowthKeyboard3DRenderer(layout: layout, renderFrame: { _, _ in self.fakeFrame(layout) }, schedule: scheduler.schedule)
        var selection: GrowthKeyboardKeyUsage?
        view.onSelectionChanged = { selection = $0 }
        view.apply([.init(id: "A", count: 73)])
        view.setActive(true); scheduler.fireAll()
        view.selectKey("A")
        XCTAssertEqual(selection?.count, 73)
        XCTAssertEqual(view.renderCount, 1)
        view.clearHover(); scheduler.fireAll()
        XCTAssertEqual(view.renderCount, 1)
        view.apply([.init(id: "A", count: 81)])
        XCTAssertEqual(selection?.count, 73)
        scheduler.fireAll()
        XCTAssertEqual(selection?.count, 81)
        XCTAssertEqual(view.renderCount, 2)
        view.selectKey("not-a-key")
        XCTAssertNil(selection)
        XCTAssertEqual(view.renderCount, 2)
    }

    func testFormalHistoryMapsTo3DWithCalendarGapsAndModifierFallback() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        func day(_ key: String, counts: [String: Int]) -> DailyStats {
            var value = DailyStats(date: formatter.date(from: key)!)
            value.keyPresses = counts.values.reduce(0, +); value.keyPressCounts = counts
            return value
        }
        let history = ["2026-10-01": day("2026-10-01", counts: ["Cmd+A": 3]),
                       "2026-10-03": day("2026-10-03", counts: ["A": 7, "Shift++": 2])]
        let period = try XCTUnwrap(KeyboardTrackingPeriod(history: history, calendar: calendar, dateKeyFormatter: formatter))
        let presentation = try XCTUnwrap(GrowthKeyboardPresentation(timeline: CumulativeKeyboardTimeline.build(history: history),
            period: period, now: formatter.date(from: "2026-10-03")!, calendar: calendar))
        let layout = layout(), scheduler = StaticRenderScheduler()
        var received: [[GrowthKeyboardKeyUsage]] = []
        let view = GrowthKeyboard3DRenderer(layout: layout, renderFrame: { values, _ in
            received.append(values); return self.fakeFrame(layout)
        }, schedule: scheduler.schedule)
        view.setActive(true)
        for day in 0..<3 { view.apply(presentation.frame(at: day).keyUsages); scheduler.fireAll() }
        XCTAssertEqual(received.count, 2) // Missing calendar date reuses the same cumulative geometry.
        XCTAssertEqual(received[0].first { $0.id == "A" }?.count, 3)
        XCTAssertEqual(received[1].first { $0.id == "A" }?.count, 10)
        XCTAssertEqual(received[1].first { $0.id == "=" }?.count, 2)
        XCTAssertEqual(received[1].first { $0.id == "LeftCmd" }?.count, 3)
        XCTAssertEqual(received[1].first { $0.id == "RightCmd" }?.count, 0)
        XCTAssertEqual(received[1].count, 77)
    }
}

final class GrowthReplayPressTests: XCTestCase {
    private func usage(_ a: Int, _ s: Int = 0) -> [GrowthKeyboardKeyUsage] {
        [.init(id: "A", count: a), .init(id: "S", count: s)]
    }
    private func frame() -> GrowthKeyboard3DFrame {
        let layout = EditorialKeyboardRenderer(frame: .zero).sceneLayout
        return .init(image: NSImage(size: GrowthKeyboard3DScene.size),
            rects: Dictionary(uniqueKeysWithValues: layout.keys.map { ($0.id, $0.rect) }))
    }
    private func plan() -> GrowthReplayPressPlan {
        GrowthReplayPressPlan(day: KeyReplayDay(entries: [
            .init(seconds: 0, event: .init(milliseconds: 0, ordinal: 0, keyCode: 0, phase: .down, growthKeys: ["A"]), startsSession: true),
            .init(seconds: 0.1, event: .init(milliseconds: 100, ordinal: 1, keyCode: 0, phase: .up, growthKeys: []), startsSession: false)
        ], hasUnreadableChunks: false))
    }
    func testNoRecordsNeverFabricatesASequence() {
        XCTAssertTrue(GrowthReplayPressPlan(day: .empty).entries.isEmpty)
        XCTAssertEqual(GrowthReplayPressPlan(day: .empty).duration(profile: .light), 0)
    }
    func testReplayRetainsPresentedCountsUntilPressFinishesEvenOnCacheHit() {
        let scheduler = StaticRenderScheduler()
        var finish: (() -> Void)?
        var received: [String] = []
        let renderer = GrowthKeyboard3DRenderer(layout: EditorialKeyboardRenderer(frame: .zero).sceneLayout,
            renderFrame: { _,_ in self.frame() }, replayPress: { plan, _, _, done in
                received = plan.ids; finish = done; return {}
            }, reduceMotion: { false }, schedule: scheduler.schedule)
        renderer.setActive(true)
        renderer.apply(usage(2));scheduler.fireAll()
        renderer.apply(usage(1));scheduler.fireAll() // Both endpoints in LRU.
        var count = -1, acknowledgements = 0
        renderer.onSelectionChanged = { count = $0?.count ?? -1 }
        renderer.selectKey("A")
        renderer.apply(usage(2), animated: true, replayFrom: usage(1), recordedReplay: plan()) { acknowledgements += 1 }
        XCTAssertEqual(received, ["A"])
        XCTAssertTrue(renderer.isReplayingPress)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(acknowledgements, 0)
        finish?()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(acknowledgements, 1)
        XCTAssertFalse(renderer.isReplayingPress)
        XCTAssertEqual(renderer.renderCount, 2)
    }
    func testHiddenOrNewDateCancelsOldAnimationAndRejectsItsCompletion() {
        let scheduler = StaticRenderScheduler()
        var callbacks: [() -> Void] = []
        var cancels = 0
        let renderer = GrowthKeyboard3DRenderer(layout: EditorialKeyboardRenderer(frame: .zero).sceneLayout,
            renderFrame: { _,_ in self.frame() }, replayPress: { _,_,_,done in
                callbacks.append(done); return { cancels += 1 }
            }, reduceMotion: { false }, schedule: scheduler.schedule)
        renderer.setActive(true);renderer.apply(usage(1));scheduler.fireAll()
        var acknowledged = 0
        renderer.apply(usage(2), animated: true, replayFrom: usage(1), recordedReplay: plan()) { acknowledged += 1 }
        scheduler.fireAll()
        renderer.setActive(false)
        XCTAssertEqual(cancels, 1)
        callbacks[0]()
        XCTAssertEqual(acknowledged, 0)
        XCTAssertFalse(renderer.isReplayingPress)
        renderer.setActive(true) // Complete the pending full frame without replaying the press.
        XCTAssertEqual(acknowledged, 1)
        renderer.apply(usage(3), animated: true, replayFrom: usage(2), recordedReplay: plan())
        scheduler.fireAll()
        renderer.apply(usage(9)) { acknowledged += 10 }
        scheduler.fireAll()
        callbacks[1]()
        XCTAssertEqual(acknowledged, 11)
        XCTAssertEqual(cancels, 2)
    }
    func testReducedMotionAndZeroDeltaSkipPressAndStillAcknowledge() {
        let scheduler = StaticRenderScheduler()
        let renderer = GrowthKeyboard3DRenderer(layout: EditorialKeyboardRenderer(frame: .zero).sceneLayout,
            renderFrame: { _,_ in self.frame() }, replayPress: { _,_,_,_ in
                XCTFail("Reduced Motion must not start a press renderer"); return {}
            }, reduceMotion: { true }, schedule: scheduler.schedule)
        renderer.setActive(true);renderer.apply(usage(1));scheduler.fireAll()
        var acknowledged = 0
        renderer.apply(usage(2), animated: true, replayFrom: usage(1), recordedReplay: plan()) { acknowledged += 1 }
        scheduler.fireAll()
        renderer.apply(usage(2), animated: true, replayFrom: usage(2), recordedReplay: plan()) { acknowledged += 1 }
        XCTAssertEqual(acknowledged, 2)
        XCTAssertFalse(renderer.isReplayingPress)
        XCTAssertNil(renderer.layer?.animation(forKey: kCATransition))
    }
    func testPlaybackDriverWaitsForPressCompletionBeforeSchedulingNextDay() {
        let renders = StaticRenderScheduler()
        var steps: [() -> Void] = [], finish: (() -> Void)?
        let driver = GrowthPlaybackDriver(schedule: { _, action in steps.append(action); return {} })
        driver.waitsForPresentation = true
        let renderer = GrowthKeyboard3DRenderer(layout: EditorialKeyboardRenderer(frame: .zero).sceneLayout,
            renderFrame: { _,_ in self.frame() }, replayPress: { _,_,_, done in finish = done; return {} },
            reduceMotion: { false }, schedule: renders.schedule)
        renderer.setActive(true)
        driver.onChange = { offset in
            let generation = driver.presentationGeneration
            renderer.apply(self.usage(offset + 1), animated: driver.isPresentingPlaybackFrame,
                replayFrom: offset > 0 ? self.usage(offset) : nil, recordedReplay: self.plan()) {
                driver.framePresented(at: offset, generation: generation)
            }
        }
        driver.reset(dayCount: 3);driver.setActive(true);driver.start();renders.fireAll()
        XCTAssertEqual(steps.count, 1)
        steps.removeFirst()();renders.fireAll()
        XCTAssertTrue(renderer.isReplayingPress)
        XCTAssertTrue(steps.isEmpty)
        finish?()
        XCTAssertEqual(steps.count, 1)
    }
}
