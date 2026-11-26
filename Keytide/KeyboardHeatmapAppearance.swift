import AppKit

struct KeyboardHeatmapTheme: Equatable {
    static let defaultsKey = "menuHeatmap.themeRGB.v1"
    static let green = KeyboardHeatmapTheme()
    static let blue = KeyboardHeatmapTheme(rgb: 0x2474D1)
    static let purple = KeyboardHeatmapTheme(rgb: 0x8B50CA)
    static let amber = KeyboardHeatmapTheme(rgb: 0xCF750E)
    static let defaultTheme = blue
    // An explicit Classic Green selection needs a value distinct from an unset preference.
    private static let classicGreenPreference = -1

    let rgb: Int?

    init(rgb: Int? = nil) {
        self.rgb = rgb.flatMap { (0...0xFFFFFF).contains($0) ? $0 : nil }
    }

    init(color: NSColor) {
        guard let color = color.usingColorSpace(.sRGB) else { self = Self.defaultTheme; return }
        let red = Self.colorByte(color.redComponent)
        let green = Self.colorByte(color.greenComponent)
        let blue = Self.colorByte(color.blueComponent)
        self.init(rgb: (red << 16) | (green << 8) | blue)
    }

    static func legacyValue(in defaults: UserDefaults) -> Self {
        let storedRGB = defaults.object(forKey: defaultsKey) as? Int
        if storedRGB == classicGreenPreference { return .green }
        let theme = Self(rgb: storedRGB)
        return theme.rgb == nil ? defaultTheme : theme
    }

    var pickerColor: NSColor { Self.color(rgb ?? 0x38A657) }

    func palette(isDark: Bool) -> [NSColor] {
        let original = isDark ? Self.darkGreen : Self.lightGreen
        guard rgb != nil else { return original }

        // Use the selected RGB as the hue source, with fixed endpoints for a readable ramp.
        let base = pickerColor
        let saturation = min(0.95, base.saturationComponent * 0.9)
        let hue = base.hueComponent
        let strengths: [CGFloat] = isDark ? [0.42, 0.62, 0.75, 0.88] : [0.24, 0.45, 0.68, 0.84]
        let brightness: [CGFloat] = isDark ? [0.66, 0.56, 0.44, 0.34] : [0.89, 0.80, 0.64, 0.46]
        let adjustment = (base.brightnessComponent - 0.65) * 0.16
        let ramp = zip(strengths, brightness).map { strength, value in
            NSColor(hue: hue, saturation: saturation * strength, brightness: min(0.92, value + adjustment), alpha: 1)
        }
        return [original[0]] + ramp
    }

    private static let lightGreen = [0xEBEEF1, 0xB8EFC0, 0x72D58B, 0x38A657, 0x196C38].map(color)
    private static let darkGreen = [0x28323B, 0x528266, 0x377E52, 0x236940, 0x10502D].map(color)

    private static func color(_ rgb: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    private static func colorByte(_ component: CGFloat) -> Int {
        Int((min(1, max(0, component)) * 255).rounded())
    }
}

enum KeyboardHeatmapEffect: String, CaseIterable, Codable {
    case still, constellation, ripple

    static let defaultsKey = "menuHeatmap.effect.v1"
    static func legacyValue(in defaults: UserDefaults) -> Self {
        let saved = defaults.string(forKey: defaultsKey) ?? ""
        if saved == "trail" { return .constellation }
        return Self(rawValue: saved) ?? .still
    }

    var title: String { NSLocalizedString("menuHeatmap.effect." + rawValue, comment: "") }

    var frameInterval: TimeInterval { self == .constellation ? 1.0 / 30 : 0.085 }
}

struct KeyboardHeatmapEffects {
    enum Frame: Equatable {
        case ripple([String: CGFloat])
        case constellation(Constellation)
    }

    struct Constellation: Equatable {
        struct NamedGroup: Equatable {
            enum Pattern: String {
                case loneStar, scatteredStars, twinLights, longString, silverHook, wings
                case triangle, crown, zigzag, cross, gemini
                case orion, delphinus, cepheus, lyra, pegasus, aquila, scorpius, leo

                var title: String {
                    NSLocalizedString("menuHeatmap.constellation.name." + rawValue, comment: "")
                }

                var originalTitle: String {
                    switch self {
                    case .loneStar: return "Stella Solitaria"
                    case .scatteredStars: return "Stellae Sparsae"
                    case .twinLights: return "Lumina Gemina"
                    case .longString: return "Chorda Argentea"
                    case .silverHook: return "Hamus Argenteus"
                    case .wings: return "Alae Stellarum"
                    case .triangle: return "Triangulum"
                    case .crown: return "Corona Stellaris"
                    case .zigzag: return "Cassiopeia"
                    case .cross: return "Crux"
                    case .gemini: return "Gemini"
                    case .orion: return "Orion"
                    case .delphinus: return "Delphinus"
                    case .cepheus: return "Cepheus"
                    case .lyra: return "Lyra"
                    case .pegasus: return "Pegasus"
                    case .aquila: return "Aquila"
                    case .scorpius: return "Scorpius"
                    case .leo: return "Leo"
                    }
                }
            }

            let pattern: Pattern
            let firstKey: String
        }

        struct Anchor: Hashable {
            enum Placement: CaseIterable {
                case topLeft, topRight, bottomLeft, bottomRight, center
            }

            let key: String
            let placement: Placement

            init(_ key: String, placement: Placement = .topLeft) {
                self.key = key
                self.placement = placement
            }

            func point(in cap: CGRect) -> CGPoint {
                let x = min(0.24, cap.width * 0.28)
                let y = min(0.24, cap.height * 0.4)
                switch placement {
                case .topLeft: return CGPoint(x: cap.minX + x, y: cap.minY + y)
                case .topRight: return CGPoint(x: cap.maxX - x, y: cap.minY + y)
                case .bottomLeft: return CGPoint(x: cap.minX + x, y: cap.maxY - y)
                case .bottomRight: return CGPoint(x: cap.maxX - x, y: cap.maxY - y)
                case .center: return CGPoint(x: cap.midX, y: cap.midY)
                }
            }
        }

        struct Star: Equatable {
            let brightness: CGFloat
            let arrivalPulse: CGFloat
        }

        struct Link: Equatable {
            let from: Anchor
            let to: Anchor
            let progress: CGFloat
        }

        let stars: [Anchor: Star]
        let links: [Link]
        let opacity: CGFloat
        let namedGroups: [NamedGroup]
        let geminiWash: CGFloat
    }

    let positions: [String: CGRect]
    let counts: [String: Int]

    private typealias Pattern = Constellation.NamedGroup.Pattern
    private typealias Anchor = Constellation.Anchor
    private typealias KeyStep = (source: String?, key: String)
    private typealias Step = (source: Anchor?, target: Anchor)

    private struct Group {
        let name: Constellation.NamedGroup
        var closingEdge: (from: Anchor, to: Anchor)? = nil
    }

    private struct Layout {
        let origin: Anchor
        let order: [Step]
        let groups: [Group]
        var geminiKeys: Set<String> = []

        init(origin: Anchor, order: [Step], groups: [Group]) {
            self.origin = origin
            self.order = order
            self.groups = groups
        }

        init(origin: String, order: [KeyStep], groups: [Group], geminiKeys: Set<String> = []) {
            self.init(origin: Anchor(origin), order: order.map { ($0.source.map { Anchor($0) }, Anchor($0.key)) },
                      groups: groups)
            self.geminiKeys = geminiKeys
        }
    }

    func frames(for effect: KeyboardHeatmapEffect, from selected: String?,
                avoiding previous: Set<Constellation.NamedGroup.Pattern> = []) -> [Frame] {
        var random = SystemRandomNumberGenerator()
        return frames(for: effect, from: selected, avoiding: previous, using: &random)
    }

    func geminiPreviewFrames() -> [Frame] {
        let origin = "E"
        let destinations = ["D", "C", "R", "F", "V"]
        guard let twins = geminiChains(in: [origin] + destinations) else { return [] }
        return constellationFrames(geminiLayout(from: origin, destinations: destinations, chains: twins))
    }

    func frames(for effect: KeyboardHeatmapEffect, from selected: String?,
                avoiding previous: Set<Constellation.NamedGroup.Pattern> = [],
                using random: inout some RandomNumberGenerator) -> [Frame] {
        guard effect != .still, !positions.isEmpty else { return [] }
        let ranked = positions.keys.sorted { first, second in
            let firstCount = counts[first, default: 0]
            let secondCount = counts[second, default: 0]
            return firstCount == secondCount ? first < second : firstCount > secondCount
        }
        let selected = selected.flatMap { positions[$0] == nil ? nil : $0 }
        switch effect {
        case .still: return []
        case .constellation:
            let used = ranked.filter { counts[$0, default: 0] > 0 }
            guard selected != nil || !used.isEmpty else { return [] }
            let peak = Double(used.first.map { counts[$0, default: 1] } ?? 1)
            // Keep ties, but do not let a crowd of rarely used keys spill into the hot group.
            let fifthCount = used.prefix(5).last.map { counts[$0, default: 0] } ?? 0
            let cutoff = max(Double(fifthCount), peak * 0.08)
            let hot = Array(used.prefix { Double(counts[$0, default: 0]) >= cutoff })
            var layout = constellationLayout(from: selected, used: used, hot: hot, peak: peak, using: &random)
            for _ in 0..<4 where !previous.isEmpty {
                let repeats = repeatedPatterns(in: layout, previous: previous)
                guard repeats > 0, used.count > 2 else { break }
                let candidate = constellationLayout(from: selected, used: used, hot: hot, peak: peak, using: &random)
                if repeatedPatterns(in: candidate, previous: previous) < repeats { layout = candidate }
            }
            // Give autoplay and replay an extra draw from active keys, while keeping the hot origin.
            if selected == nil, layout.geminiKeys.isEmpty, !previous.contains(.gemini), used.count >= 6,
               Int.random(in: 0..<8, using: &random) == 0,
               let twins = geminiChains(in: Array(used.prefix(18))) ?? geminiChains(in: used) {
                let destinations = (twins.left + twins.right).filter { $0 != layout.origin.key }
                layout = geminiLayout(from: layout.origin.key, destinations: destinations, chains: twins)
            }
            if layout.geminiKeys.isEmpty, used.count >= 4,
               (repeatedPatterns(in: layout, previous: previous) > 0 || Bool.random(using: &random)),
               let figure = catalogLayout(from: layout.origin.key, used: used, hot: hot, peak: peak,
                                          avoiding: previous, using: &random) {
                layout = figure
            }
            return constellationFrames(layout)
        case .ripple:
            guard let origin = positions[selected ?? ranked[0]] else { return [] }
            return ripple(from: origin)
        }
    }

    private func repeatedPatterns(in layout: Layout, previous: Set<Pattern>) -> Int {
        Set(layout.groups.map(\.name.pattern)).intersection(previous).count
    }

    private func constellationLayout(from selected: String?, used: [String], hot: [String], peak: Double,
                                     using random: inout some RandomNumberGenerator) -> Layout {
        let origin = selected ?? weightedKey(in: hot, peak: peak, using: &random) ?? used[0]
        var remaining = used.filter { $0 != origin }
        let minimum = remaining.count < 4 ? 1 : 2
        let limit = min(remaining.count, Int.random(in: minimum...6, using: &random))
        var destinations: [String] = []
        if let anchor = weightedKey(in: hot.filter { $0 != origin }, peak: peak, using: &random) {
            destinations.append(anchor)
            remaining.removeAll { $0 == anchor }
        }
        // Give the long tail a slot even when the same few keys dominate every day.
        let hotKeys = Set(hot)
        if destinations.count < limit,
           let explorer = weightedKey(in: remaining.filter { !hotKeys.contains($0) }, peak: peak, using: &random) {
            destinations.append(explorer)
            remaining.removeAll { $0 == explorer }
        }
        while destinations.count < limit,
              let key = weightedKey(in: remaining, peak: peak, using: &random) {
            destinations.append(key)
            remaining.removeAll { $0 == key }
        }
        let twins = geminiChains(in: ([origin] + destinations).filter { counts[$0, default: 0] > 0 })
        if let twins {
            return geminiLayout(from: origin, destinations: destinations, chains: twins)
        }
        let order = constellationOrder(from: origin, to: destinations, using: &random)
        return Layout(origin: origin, order: order, groups: constellationGroups(from: origin, order: order))
    }

    private func geminiLayout(from origin: String, destinations: [String], chains: (left: [String], right: [String])) -> Layout {
        Layout(origin: origin, order: geminiOrder(from: origin, destinations: destinations, chains: chains),
               groups: [Group(name: .init(pattern: .gemini, firstKey: origin))], geminiKeys: Set(chains.left + chains.right))
    }

    private func weightedKey(in keys: [String], peak: Double, using random: inout some RandomNumberGenerator) -> String? {
        guard !keys.isEmpty else { return nil }
        // Compress very large count differences while still favoring frequent keys at every draw.
        let weights = keys.map { 0.12 + 0.88 * sqrt(Double(counts[$0, default: 0]) / peak) }
        var roll = Double.random(in: 0..<weights.reduce(0, +), using: &random)
        for (key, weight) in zip(keys, weights) {
            if roll < weight { return key }
            roll -= weight
        }
        return keys.last
    }

    private func constellationFrames(_ layout: Layout) -> [Frame] {
        let order = layout.order
        let stars = [layout.origin] + order.map(\.target)
        let namedGroups = layout.groups.map(\.name)
        let framesPerLink = 8
        let leadIn = 7
        func arrival(at index: Int) -> Int { index == 0 ? 0 : leadIn + index * framesPerLink }
        let closures = layout.groups.compactMap(\.closingEdge).compactMap { edge -> (from: Anchor, to: Anchor, start: Int)? in
            guard let last = stars.lastIndex(where: { $0 == edge.from || $0 == edge.to }) else { return nil }
            return (edge.from, edge.to, arrival(at: last))
        }
        let completed = max(arrival(at: order.count), (closures.map(\.start).max() ?? 0) + framesPerLink)
        let geminiArrival = stars.lastIndex { layout.geminiKeys.contains($0.key) }.map { arrival(at: $0) }
        let fadeStart = completed + (geminiArrival == nil ? 22 : 40)
        let fadeFrames = 14

        return (0...(fadeStart + fadeFrames)).map { step in
            let visibleStars = stars.enumerated().reduce(into: [Anchor: Constellation.Star]()) { result, entry in
                let (index, key) = entry
                let arrival = arrival(at: index)
                guard step >= arrival else { return }
                let age = step - arrival
                let twinkle = 0.92 + 0.08 * cos(CGFloat(age + index * 7) * 0.23)
                let hasIncomingLink = index > 0 && order[index - 1].source != nil
                let pulse = hasIncomingLink ? 1 - smoothstep(CGFloat(age) / 10) : 0
                let brightness = smoothstep(CGFloat(age + 1) / 6) * twinkle
                result[key] = .init(brightness: max(brightness, pulse), arrivalPulse: pulse)
            }
            var visibleLinks = order.enumerated().compactMap { index, entry -> Constellation.Link? in
                let elapsed = step - leadIn - index * framesPerLink
                guard elapsed > 0, let source = entry.source else { return nil }
                let progress = smoothstep(CGFloat(elapsed) / CGFloat(framesPerLink))
                return Constellation.Link(from: source, to: entry.target, progress: progress)
            }
            for edge in closures where step > edge.start {
                let progress = smoothstep(CGFloat(step - edge.start) / CGFloat(framesPerLink))
                visibleLinks.append(.init(from: edge.from, to: edge.to, progress: progress))
            }
            let fadeIn = smoothstep(CGFloat(step + 1) / CGFloat(leadIn))
            let fadeOut = smoothstep(CGFloat(step - fadeStart) / CGFloat(fadeFrames))
            let opacity = fadeIn * (1 - fadeOut)
            let geminiWash = geminiArrival.map { smoothstep(CGFloat(step - $0) / 12) * (1 - fadeOut) } ?? 0
            return .constellation(.init(stars: visibleStars, links: visibleLinks, opacity: opacity,
                                        namedGroups: namedGroups, geminiWash: geminiWash))
        }
    }

    private func smoothstep(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    private func geminiChains(in keys: [String]) -> (left: [String], right: [String])? {
        guard keys.count >= 6 else { return nil }
        let located: [(key: String, frame: CGRect)] = keys.compactMap { key in
            guard let frame = positions[key] else { return nil }
            return (key, frame)
        }
        let caps = located.sorted { first, second in
            let firstX = first.frame.midX
            let secondX = second.frame.midX
            return firstX == secondX ? first.key < second.key : firstX < secondX
        }
        let pairs = caps.enumerated().flatMap { index, left in
            caps.dropFirst(index + 1).compactMap { right -> (left: String, right: String, x: CGFloat, y: CGFloat, gap: CGFloat)? in
                let gap = right.frame.midX - left.frame.midX
                guard (0.9...4.5).contains(gap), abs(left.frame.midY - right.frame.midY) < 0.3 else { return nil }
                return (left.key, right.key, left.frame.midX, left.frame.midY, gap)
            }
        }
        // Gemini's twins reduce to two nearby, near-parallel chains on the keyboard.
        for top in pairs {
            for middle in pairs where (0.85...1.65).contains(middle.y - top.y) && abs(middle.x - top.x) < 1.35 {
                for bottom in pairs where (0.85...1.65).contains(bottom.y - middle.y) && abs(bottom.x - middle.x) < 1.35 {
                    let spread = max(top.gap, middle.gap, bottom.gap) - min(top.gap, middle.gap, bottom.gap)
                    guard spread < 0.8, abs(bottom.x - top.x) < 1.8 else { continue }
                    return ([top.left, middle.left, bottom.left], [top.right, middle.right, bottom.right])
                }
            }
        }
        return nil
    }

    private func geminiOrder(from origin: String, destinations: [String], chains: (left: [String], right: [String])) -> [KeyStep] {
        let first = chains.right.contains(origin) ? chains.right : chains.left
        let second = first == chains.left ? chains.right : chains.left
        var order: [KeyStep] = []
        if let start = first.firstIndex(of: origin) {
            for index in first.indices.dropFirst(start + 1) {
                order.append((first[index - 1], first[index]))
            }
            for index in (0..<start).reversed() {
                order.append((first[index + 1], first[index]))
            }
        } else {
            order.append(contentsOf: [(nil, first[0]), (first[0], first[1]), (first[1], first[2])])
        }
        order.append(contentsOf: [(nil, second[0]), (second[0], second[1]), (second[1], second[2])])
        order.append(contentsOf: destinations.filter { !first.contains($0) && !second.contains($0) }.map { (nil, $0) })
        return order
    }

    private func constellationGroups(from origin: String, order: [KeyStep]) -> [Group] {
        var groups = [[origin]]
        var groupIndex = [origin: 0]
        var neighbors: [String: [String]] = [:]
        for entry in order {
            if let source = entry.source, let index = groupIndex[source] {
                groups[index].append(entry.key)
                groupIndex[entry.key] = index
                neighbors[source, default: []].append(entry.key)
                neighbors[entry.key, default: []].append(source)
            } else {
                groupIndex[entry.key] = groups.count
                groups.append([entry.key])
            }
        }

        let connected = groups.compactMap { keys -> Group? in
            guard keys.count > 1, let firstKey = keys.first else { return nil }
            func group(_ pattern: Pattern, closingEdge: (String, String)? = nil) -> Group {
                Group(name: .init(pattern: pattern, firstKey: firstKey),
                      closingEdge: closingEdge.map { (Anchor($0.0), Anchor($0.1)) })
            }
            if keys.count == 2 {
                return group(.twinLights)
            }
            if keys.contains(where: { isCross(center: $0, neighbors: neighbors[$0, default: []]) }) {
                return group(.cross)
            }
            if keys.contains(where: { neighbors[$0, default: []].count > 2 }) {
                return group(.wings)
            }
            // Walking from a leaf describes the geometry regardless of the animated start key.
            guard let leaf = keys.first(where: { neighbors[$0, default: []].count == 1 }) else { return group(.silverHook) }
            var path = [leaf]
            var current = leaf
            while let next = neighbors[current, default: []].first(where: { !path.contains($0) }) {
                path.append(next)
                current = next
            }
            let points = path.compactMap(center(of:))
            let turns = zip(zip(points, points.dropFirst()), points.dropFirst(2)).map { pair, end in
                turn(from: pair.0, through: pair.1, to: end)
            }
            if path.count == 3, let last = path.last, let startPoint = points.first, let endPoint = points.last,
               hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y) <= 3,
               (0.45...1).contains(abs(turns.first ?? 0)) {
                return group(.triangle, closingEdge: (leaf, last))
            }
            let corners = turns.filter { abs($0) >= 0.38 }
            if corners.count >= 3, zip(corners, corners.dropFirst()).allSatisfy({ $0 * $1 < 0 }) {
                return group(.zigzag)
            }
            if corners.count >= 2, let first = corners.first, corners.allSatisfy({ $0 * first > 0 }) {
                return group(.crown)
            }
            return group(turns.allSatisfy { abs($0) < 0.25 } ? .longString : .silverHook)
        }
        if connected.isEmpty {
            return [Group(name: .init(pattern: groups.count == 1 ? .loneStar : .scatteredStars, firstKey: origin))]
        }
        return connected
    }

    private func center(of key: String) -> CGPoint? {
        positions[key].map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    private func turn(from start: CGPoint, through middle: CGPoint, to end: CGPoint) -> CGFloat {
        let incoming = CGPoint(x: middle.x - start.x, y: middle.y - start.y)
        let outgoing = CGPoint(x: end.x - middle.x, y: end.y - middle.y)
        let length = hypot(incoming.x, incoming.y) * hypot(outgoing.x, outgoing.y)
        guard length > 0 else { return 0 }
        return (incoming.x * outgoing.y - incoming.y * outgoing.x) / length
    }

    private func isCross(center key: String, neighbors: [String]) -> Bool {
        guard neighbors.count == 4, let center = center(of: key) else { return false }
        let angles = neighbors.compactMap(self.center(of:)).map { atan2($0.y - center.y, $0.x - center.x) }.sorted()
        guard let first = angles.first else { return false }
        let circular = angles + [first + 2 * .pi]
        return zip(circular, circular.dropFirst()).allSatisfy { $1 - $0 < 2.4 }
    }

    private func constellationOrder(from origin: String, to destinations: [String],
                                    using random: inout some RandomNumberGenerator) -> [KeyStep] {
        var joined = [origin]
        var remaining = destinations
        var order: [KeyStep] = []
        while !remaining.isEmpty {
            var links: [(from: String, index: Int, distance: CGFloat)] = []
            for source in joined {
                guard let start = center(of: source) else { continue }
                for (index, target) in remaining.enumerated() {
                    guard let end = center(of: target) else { continue }
                    links.append((source, index, hypot(start.x - end.x, start.y - end.y)))
                }
            }
            guard let nearest = links.min(by: { $0.distance < $1.distance }) else { break }
            let nearby = links.filter { $0.distance <= min(4.5, nearest.distance + 0.55) }
            let next = nearby.randomElement(using: &random) ?? nearest
            let target = remaining.remove(at: next.index)
            // Start a new group when a line would span several unrelated keys.
            let source = destinations.count >= 3 && next.distance > 4.5 ? nil : next.from
            order.append((source, target))
            joined.append(target)
        }
        return order
    }

    private func ripple(from origin: CGRect) -> [Frame] {
        let arrival = positions.mapValues { rect in
            Int((hypot(rect.midX - origin.midX, rect.midY - origin.midY) / 0.85).rounded())
        }
        let fade: [CGFloat] = [1, 0.72, 0.42, 0.16]
        let length = (arrival.values.max() ?? 0) + fade.count
        return (0..<length).map { step in
            let highlights = arrival.reduce(into: [String: CGFloat]()) { frame, entry in
                let age = step - entry.value
                if fade.indices.contains(age) { frame[entry.key] = fade[age] }
            }
            return .ripple(highlights)
        }
    }
}

extension KeyboardHeatmapEffects {
    private struct Figure {
        let pattern: Constellation.NamedGroup.Pattern
        let points: [(x: CGFloat, y: CGFloat)]
        // Each vertex after the first names its parent. A final edge may close a loop.
        let parents: [Int]
        var closingEdge: (Int, Int)? = nil
    }

    // Compact interpretations of the familiar sky outlines, in key pitches.
    private static let catalog: [Figure] = [
        .init(pattern: .orion, points: [(0, 1), (1, 1), (2, 1), (-1, 0), (3, 0), (-1, 2), (3, 2)],
              parents: [0, 1, 0, 2, 0, 2]),
        .init(pattern: .delphinus, points: [(0, 0), (1, 1), (0, 2), (-1, 1), (-1, 3)],
              parents: [0, 1, 2, 2], closingEdge: (3, 0)),
        .init(pattern: .cepheus, points: [(0, 0), (-1, 1), (-1, 2), (1, 2), (1, 1)],
              parents: [0, 1, 2, 3], closingEdge: (4, 0)),
        .init(pattern: .lyra, points: [(-1, 0), (0, 1), (2, 1), (3, 2), (1, 2)],
              parents: [0, 1, 2, 3], closingEdge: (4, 1)),
        .init(pattern: .pegasus, points: [(0, 0), (2, 0), (2, 2), (0, 2), (-1, 1), (-2, 1)],
              parents: [0, 1, 2, 0, 4], closingEdge: (3, 0)),
        .init(pattern: .aquila, points: [(0, 0), (0, 1), (0, 2), (-1, 2), (-3, 1), (1, 2), (3, 1)],
              parents: [0, 1, 1, 3, 1, 5]),
        .init(pattern: .scorpius, points: [(0, 0), (2, 1), (3, 2), (5, 2), (6, 1), (5, 0)],
              parents: [0, 1, 2, 3, 4]),
        .init(pattern: .leo, points: [(0, 0), (-1, 0), (-2, 1), (-1, 2), (0, 2), (3, 2), (2, 1)],
              parents: [0, 1, 2, 3, 4, 5], closingEdge: (6, 4))
    ]

    private struct AnchorCell: Hashable {
        let x: Int
        let y: Int

        init(x: CGFloat, y: CGFloat) {
            self.x = Int(floor(x))
            self.y = Int(floor(y))
        }

        init(_ point: CGPoint) { self.init(x: point.x, y: point.y) }

        init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }

    private struct LocatedAnchor {
        let anchor: Constellation.Anchor
        let point: CGPoint
        let heat: CGFloat
    }

    private func catalogLayout(from origin: String, used: [String], hot: [String], peak: Double,
                               avoiding previous: Set<Pattern>, using random: inout some RandomNumberGenerator) -> Layout? {
        let figures = Self.catalog.filter { !previous.contains($0.pattern) }.shuffled(using: &random)
        guard !figures.isEmpty else { return nil }
        let placements = Anchor.Placement.allCases.shuffled(using: &random)
        let hotKeys = Set(hot)
        let requireExplorer = used.count > hotKeys.count
        let requiredHot = min(hotKeys.count, hotKeys.contains(origin) ? 2 : 1)

        func anchors(for key: String) -> [LocatedAnchor] {
            guard let cap = positions[key] else { return [] }
            let heat = CGFloat(sqrt(Double(max(0, counts[key, default: 0])) / peak))
            return placements.map { placement in
                let anchor = Anchor(key, placement: placement)
                return LocatedAnchor(anchor: anchor, point: anchor.point(in: cap), heat: heat)
            }
        }

        // Searching a small neighborhood per vertex bounds the work even with a full keyboard.
        let active = [origin] + used.filter { $0 != origin }
        let grid = Dictionary(grouping: active.flatMap(anchors(for:))) { AnchorCell($0.point) }
        let startingKeys = [origin] + hot.filter { $0 != origin }.prefix(4)
        let starts = startingKeys.flatMap(anchors(for:))
        let directions: [CGFloat] = Bool.random(using: &random) ? [1, -1] : [-1, 1]
        let pitches: [CGFloat] = [1.15, 0.86, 0.70]

        for figure in figures {
            let vertices = figure.points.indices.shuffled(using: &random)
            for start in starts {
                for vertex in vertices {
                    for pitch in pitches {
                        for direction in directions {
                            guard let fitted = fit(figure, startingAt: vertex, anchor: start, pitch: pitch,
                                                   direction: direction, grid: grid) else { continue }
                            let keys = Set(fitted.map(\.key)).union([origin])
                            guard keys.intersection(hotKeys).count >= requiredHot,
                                  !requireExplorer || keys.contains(where: { !hotKeys.contains($0) && counts[$0, default: 0] > 0 })
                            else { continue }
                            return layout(for: figure, fitted: fitted, origin: origin, start: vertex)
                        }
                    }
                }
            }
        }
        return nil
    }

    private func fit(_ figure: Figure, startingAt vertex: Int, anchor: LocatedAnchor, pitch: CGFloat, direction: CGFloat,
                     grid: [AnchorCell: [LocatedAnchor]]) -> [Anchor]? {
        let reference = figure.points[vertex]
        let tolerance = min(0.48, pitch * 0.56)
        var fitted = Array(repeating: anchor, count: figure.points.count)
        var placed = [anchor]
        for (index, point) in figure.points.enumerated() where index != vertex {
            let target = CGPoint(x: anchor.point.x + (point.x - reference.x) * pitch * direction,
                                 y: anchor.point.y + (point.y - reference.y) * pitch)
            guard let next = nearestAnchor(to: target, within: tolerance, in: grid, excluding: placed) else { return nil }
            fitted[index] = next
            placed.append(next)
        }
        let anchors = fitted.map(\.anchor)
        // Corners on one key can share a figure, but a figure should span at least three keys.
        return Set(anchors.map(\.key)).count >= 3 ? anchors : nil
    }

    private func nearestAnchor(to target: CGPoint, within radius: CGFloat, in grid: [AnchorCell: [LocatedAnchor]],
                               excluding placed: [LocatedAnchor]) -> LocatedAnchor? {
        let lower = AnchorCell(x: target.x - radius, y: target.y - radius)
        let upper = AnchorCell(x: target.x + radius, y: target.y + radius)
        var best: LocatedAnchor?
        var bestScore = CGFloat.infinity
        for y in lower.y...upper.y {
            for x in lower.x...upper.x {
                for candidate in grid[AnchorCell(x: x, y: y), default: []] {
                    let dx = candidate.point.x - target.x
                    let dy = candidate.point.y - target.y
                    let distance = dx * dx + dy * dy
                    guard distance <= radius * radius else { continue }
                    let sameKey = placed.filter { $0.anchor.key == candidate.anchor.key }
                    guard sameKey.allSatisfy({
                        abs($0.point.x - candidate.point.x) >= 0.42 || abs($0.point.y - candidate.point.y) >= 0.42
                    }) else { continue }
                    let score = distance + (1 - candidate.heat) * 0.08 + CGFloat(sameKey.count) * 0.08
                    if score < bestScore {
                        bestScore = score
                        best = candidate
                    }
                }
            }
        }
        return best
    }

    private func layout(for figure: Figure, fitted: [Anchor], origin: String, start: Int) -> Layout {
        let originIndex = fitted.firstIndex { $0.key == origin }
        let root = fitted[originIndex ?? start]
        var order: [Step] = originIndex == nil ? [(nil, root)] : []
        var pending = figure.parents.enumerated().map { ($0.element, $0.offset + 1) }
        var visited = Set([originIndex ?? start])
        while let index = pending.firstIndex(where: { visited.contains($0.0) || visited.contains($0.1) }) {
            let (parent, child) = pending.remove(at: index)
            let (source, target) = visited.contains(parent) ? (parent, child) : (child, parent)
            order.append((fitted[source], fitted[target]))
            visited.insert(target)
        }
        let group = Group(name: .init(pattern: figure.pattern, firstKey: root.key),
                          closingEdge: figure.closingEdge.map { (fitted[$0.0], fitted[$0.1]) })
        return Layout(origin: originIndex == nil ? Anchor(origin) : root, order: order, groups: [group])
    }
}
