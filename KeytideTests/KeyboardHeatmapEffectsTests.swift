import Foundation
import XCTest
@testable import KeytideCore

final class KeyboardHeatmapEffectsTests: XCTestCase {
    private typealias Constellation = KeyboardHeatmapEffects.Constellation
    private typealias Pattern = Constellation.NamedGroup.Pattern

    func testSkewedCountsStillGiveVariedShapesWithHotAndLessUsedKeys() throws {
        let hot = ["Space": 2_000, "E": 850, "A": 540, "D": 300]
        let lessUsed = ["S", "R", "T", "H", "L", "F", "C", "V", "K", "P", "Y", "I"]
        let counts = hot.merging(Dictionary(uniqueKeysWithValues: lessUsed.map { ($0, 1) })) { hotCount, _ in hotCount }
        let effects = KeyboardHeatmapEffects(positions: keyboardPositions, counts: counts)
        var random = SeededRandom(state: 31)
        var patterns: Set<Pattern> = []
        var starSets: Set<Set<String>> = []
        var hotOrigins: [String: Int] = [:]
        for _ in 0..<120 {
            let animation = constellations(effects.frames(for: .constellation, from: nil, using: &random))
            let origin = try XCTUnwrap(animation.first?.stars.keys.first)
            let shown = try XCTUnwrap(animation.last)
            let stars = Set(shown.stars.keys)
            XCTAssertNotNil(hot[origin])
            XCTAssertGreaterThanOrEqual(stars.intersection(hot.keys).count, 2)
            XCTAssertFalse(stars.isDisjoint(with: lessUsed))
            XCTAssertTrue(stars.isSubset(of: counts.keys))
            hotOrigins[origin, default: 0] += 1
            patterns.formUnion(shown.namedGroups.map(\.pattern))
            starSets.insert(stars)
        }
        XCTAssertGreaterThan(hotOrigins["Space", default: 0], hotOrigins["D", default: 0])
        XCTAssertGreaterThanOrEqual(patterns.count, 5)
        XCTAssertGreaterThanOrEqual(starSets.count, 55)
    }

    func testReplayCanChangeShapeEvenWithOnlyThreeActiveKeys() throws {
        let effects = KeyboardHeatmapEffects(positions: keyboardPositions, counts: ["E": 800, "D": 700, "F": 200])
        var avoided = 0
        for seed in 0..<32 {
            var initial = SeededRandom(state: UInt64(seed))
            var replay = initial
            let current = constellations(effects.frames(for: .constellation, from: "E", using: &initial))
            let patterns = Set(try XCTUnwrap(current.last).namedGroups.map(\.pattern))
            let next = constellations(effects.frames(for: .constellation, from: "E", avoiding: patterns, using: &replay))
            if Set(try XCTUnwrap(next.last).namedGroups.map(\.pattern)).isDisjoint(with: patterns) { avoided += 1 }
            XCTAssertEqual(Set(next.first?.stars.keys.map { $0 } ?? []), ["E"])
        }
        XCTAssertGreaterThan(avoided, 10)
    }

    func testTriangleClosesAfterArrivalAndGeminiStillEnablesThePalette() throws {
        let triangle = KeyboardHeatmapEffects(positions: keyboardPositions, counts: ["E": 800, "D": 700, "F": 200])
        let triangles = (0..<16).lazy.map { seed in
            var random = SeededRandom(state: UInt64(seed))
            return self.constellations(triangle.frames(for: .constellation, from: "E", using: &random))
        }
        let animation = try XCTUnwrap(triangles.first { $0.last?.namedGroups.first?.pattern == .triangle })
        let firstClosingEdge = try XCTUnwrap(animation.first { $0.links.count == 3 })
        XCTAssertEqual(firstClosingEdge.stars.count, 3)
        XCTAssertTrue(animation.last!.links.allSatisfy { $0.progress == 1 })

        let twins = KeyboardHeatmapEffects(positions: keyboardPositions,
                                          counts: ["E": 800, "R": 700, "D": 600, "F": 500, "C": 400, "V": 300])
        let showsGemini = (0..<24).contains { seed in
            var random = SeededRandom(state: UInt64(seed))
            let frames = constellations(twins.frames(for: .constellation, from: nil, using: &random))
            return frames.contains { $0.namedGroups.first?.pattern == .gemini && $0.geminiWash == 1 && $0.links.count == 4 }
        }
        XCTAssertTrue(showsGemini)
    }

    func testNoDataKeepsAutoplayEmptyAndClickStillStartsFromThatKey() {
        let effects = KeyboardHeatmapEffects(positions: keyboardPositions, counts: [:])
        var random = SeededRandom(state: 1)
        XCTAssertTrue(effects.frames(for: .constellation, from: nil, using: &random).isEmpty)
        let animation = constellations(effects.frames(for: .constellation, from: "F6", using: &random))
        XCTAssertEqual(animation.last?.namedGroups, [.init(pattern: .loneStar, firstKey: "F6")])
    }

    func testGeminiPreviewReachesFullColorWithNoRecordedKeys() throws {
        let effects = KeyboardHeatmapEffects(positions: keyboardPositions, counts: [:])
        let frames = constellations(effects.geminiPreviewFrames())
        let completed = try XCTUnwrap(frames.first { $0.geminiWash == 1 })
        XCTAssertEqual(completed.namedGroups, [.init(pattern: .gemini, firstKey: "E")])
        XCTAssertEqual(Set(completed.stars.keys), ["E", "D", "C", "R", "F", "V"])
        XCTAssertEqual(completed.links.count, 4)
        XCTAssertTrue(completed.links.allSatisfy { $0.progress == 1 })
        XCTAssertEqual(completed.opacity, 1)
        XCTAssertEqual(frames.last?.geminiWash, 0)
    }

    private func constellations(_ frames: [KeyboardHeatmapEffects.Frame]) -> [Constellation] {
        frames.compactMap { frame in
            if case .constellation(let state) = frame { return state }
            return nil
        }
    }

    private var keyboardPositions: [String: CGRect] {
        let layout = KeyboardLayout.macStyle
        var positions: [String: CGRect] = [:]
        for row in layout.rows {
            var x = row.startXUnits
            for key in row.keys {
                let keyX = key.xUnits.map { row.startXUnits + $0 } ?? x
                positions[key.id] = CGRect(x: keyX, y: row.yUnits + key.yOffsetUnits,
                                          width: key.widthUnits, height: key.heightUnits)
                x = keyX + key.widthUnits + layout.keySpacingUnits
            }
        }
        return positions
    }

    private struct SeededRandom: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }
    }
}
