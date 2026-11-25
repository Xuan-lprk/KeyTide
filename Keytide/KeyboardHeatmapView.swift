import Cocoa

final class KeyboardHeatmapView: NSView, NSViewToolTipOwner {
    private struct RenderMetrics {
        let scale: CGFloat
        let origin: CGPoint
        let layoutBounds: CGRect
    }

    struct KeySpec {
        let id: String
        let label: String
        let frameUnits: CGRect
        let symbolName: String?
        let fallbackCountIDs: [String]
    }

    static let supportedKeyIDs: Set<String> = KeyboardLayout.macStyle.supportedKeyIDs
    private static let numberKeyIDs: Set<String> = Set((0...9).map(String.init))
    private static let layoutContentInset: CGFloat = 8
    private static let maximumKeyboardScale: CGFloat = 58
    private static let compactSymbols = ["shift": "⇧", "globe": "fn", "control": "⌃", "option": "⌥", "command": "⌘"]

    private static let layout: [KeySpec] = {
        let definition = KeyboardLayout.macStyle
        return definition.rows.flatMap { row in
            var x = row.startXUnits
            return row.keys.map { key in
                let keyX = key.xUnits.map { row.startXUnits + $0 } ?? x
                let spec = KeySpec(
                    id: key.id,
                    label: key.label,
                    frameUnits: CGRect(x: keyX, y: row.yUnits + key.yOffsetUnits,
                                       width: key.widthUnits, height: key.heightUnits),
                    symbolName: key.symbolName,
                    fallbackCountIDs: key.fallbackCountIDs
                )
                x = keyX + key.widthUnits + definition.keySpacingUnits
                return spec
            }
        }
    }()

    private static let positions = Dictionary(uniqueKeysWithValues: layout.map { ($0.id, $0.frameUnits) })
    private static let geminiColors: [String: NSColor] = {
        let colors = [
            NSColor(srgbRed: 0.26, green: 0.52, blue: 0.96, alpha: 1),
            NSColor(srgbRed: 0.20, green: 0.66, blue: 0.33, alpha: 1),
            NSColor(srgbRed: 0.98, green: 0.74, blue: 0.02, alpha: 1),
            NSColor(srgbRed: 0.92, green: 0.26, blue: 0.21, alpha: 1)
        ]
        let bounds = layoutBounds()
        return Dictionary(uniqueKeysWithValues: layout.map { key in
            let x = (key.frameUnits.midX - bounds.minX) / bounds.width
            let y = (key.frameUnits.midY - bounds.minY) / bounds.height
            let position = (0.85 * x + 0.15 * (1 - y)) * CGFloat(colors.count - 1)
            let index = min(colors.count - 2, Int(position))
            let color = colors[index].blended(withFraction: position - CGFloat(index), of: colors[index + 1]) ?? colors[index]
            return (key.id, color)
        })
    }()

    private let isCompact: Bool
    private let theme: KeyboardHeatmapTheme
    private lazy var lightColors = theme.palette(isDark: false)
    private lazy var darkColors = theme.palette(isDark: true)
    private var keyCounts: [String: Int] = [:]
    private var maxCount: Int = 0
    private var toolTipBounds: NSRect?
    private var toolTipKeys: [NSView.ToolTipTag: KeySpec] = [:]
    private var effectFrame: KeyboardHeatmapEffects.Frame?
    private var hoverArea: NSTrackingArea?
    private var hoveredKey: String?
    var onActivateKey: ((String) -> Void)?

    init(frame: NSRect = .zero, isCompact: Bool = false, theme: KeyboardHeatmapTheme = .defaultTheme) {
        self.isCompact = isCompact
        self.theme = theme
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        isCompact = false
        theme = .defaultTheme
        super.init(coder: coder)
    }

    private lazy var toolTipCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    override var isFlipped: Bool {
        true
    }

    func apply(keyCounts: [String: Int]) {
        guard self.keyCounts != keyCounts else { return }
        self.keyCounts = keyCounts
        self.maxCount = isCompact ? Self.layout.map(count(for:)).max() ?? 0 : keyCounts.values.max() ?? 0
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard isCompact, toolTipBounds != bounds, let metrics = renderMetrics() else { return }
        toolTipBounds = bounds
        removeAllToolTips()
        toolTipKeys.removeAll(keepingCapacity: true)
        for key in Self.layout {
            let tag = addToolTip(keyFrame(for: key.frameUnits, metrics: metrics), owner: self, userData: nil)
            toolTipKeys[tag] = key
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        guard let key = toolTipKeys[tag] else { return "" }
        return "\(key.id) · \(count(for: key).formatted())"
    }

    override func mouseDown(with event: NSEvent) {
        guard let onActivateKey else { super.mouseDown(with: event); return }
        if let key = keyID(at: event) { onActivateKey(key) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard isCompact, hoverArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if isCompact { setHoveredKey(keyID(at: event)) } else { super.mouseEntered(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        if isCompact { setHoveredKey(keyID(at: event)) } else { super.mouseMoved(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if isCompact { setHoveredKey(nil) } else { super.mouseExited(with: event) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { setHoveredKey(nil) }
    }

    private func keyID(at event: NSEvent) -> String? {
        guard let metrics = renderMetrics() else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return Self.layout.first { keyFrame(for: $0.frameUnits, metrics: metrics).contains(point) }?.id
    }

    private func setHoveredKey(_ key: String?) {
        guard isCompact, key != hoveredKey else { return }
        let previous = hoveredKey
        hoveredKey = key
        guard let metrics = renderMetrics() else { return }
        for case let changed? in [previous, key] {
            guard let rect = Self.positions[changed] else { continue }
            setNeedsDisplay(keyFrame(for: rect, metrics: metrics).insetBy(dx: -2, dy: -2))
        }
    }

    func frames(for effect: KeyboardHeatmapEffect, from key: String?,
                avoiding patterns: Set<KeyboardHeatmapEffects.Constellation.NamedGroup.Pattern>) -> [KeyboardHeatmapEffects.Frame] {
        let counts = Dictionary(uniqueKeysWithValues: Self.layout.map { ($0.id, count(for: $0)) })
        return KeyboardHeatmapEffects(positions: Self.positions, counts: counts).frames(for: effect, from: key, avoiding: patterns)
    }

    func geminiPreviewFrames() -> [KeyboardHeatmapEffects.Frame] {
        KeyboardHeatmapEffects(positions: Self.positions, counts: [:]).geminiPreviewFrames()
    }

    func showEffectFrame(_ frame: KeyboardHeatmapEffects.Frame?) {
        guard isCompact, effectFrame != frame else { return }
        effectFrame = frame
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let metrics = renderMetrics() else { return }

        let isDarkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let labelColor: NSColor = isDarkMode ? .white : .labelColor
        let palette = isCompact ? (isDarkMode ? darkColors : lightColors) : []
        let highlights: [String: CGFloat]
        let constellation: KeyboardHeatmapEffects.Constellation?
        switch effectFrame {
        case .ripple(let frame): (highlights, constellation) = (frame, nil)
        case .constellation(let frame): (highlights, constellation) = ([:], frame)
        case nil: (highlights, constellation) = ([:], nil)
        }
        let wash = constellation?.geminiWash ?? 0
        var constellationLabelColors: [String: NSColor] = [:]
        for key in Self.layout {
            let frame = keyFrame(for: key.frameUnits, metrics: metrics)
            guard !isCompact || frame.insetBy(dx: -1, dy: -1).intersects(dirtyRect) else { continue }
            let count = count(for: key)
            let level = isCompact ? compactLevel(for: count) : 0
            let strength = highlights[key.id, default: 0]
            var fillColor = isCompact ? palette[level] : color(for: count, isDarkMode: isDarkMode)
            if strength > 0 {
                let highlight = palette[level >= 3 || (isDarkMode && level == 0) ? 1 : 4]
                fillColor = fillColor.blended(withFraction: strength * 0.5, of: highlight)?.usingColorSpace(.sRGB) ?? fillColor
            }
            if wash > 0, let geminiColor = Self.geminiColors[key.id] {
                let mix = wash * (0.72 + 0.07 * CGFloat(level))
                fillColor = fillColor.blended(withFraction: mix, of: geminiColor)?.usingColorSpace(.sRGB) ?? fillColor
            }
            if key.id == hoveredKey {
                fillColor = fillColor.blended(withFraction: 0.16, of: isDarkMode ? .white : .black)?
                    .usingColorSpace(.sRGB) ?? fillColor
            }

            let radius = isCompact ? 3 : max(4, metrics.scale * 0.14)
            let keyPath = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
            fillColor.setFill()
            keyPath.fill()

            if isCompact {
                let compactLabelColor = Self.compactLabelColor(on: fillColor)
                if constellation != nil {
                    constellationLabelColors[key.id] = compactLabelColor
                    continue
                }
                drawCompactLegend(for: key, in: frame, scale: metrics.scale, textColor: compactLabelColor)
                if strength > 0 {
                    let marker = NSRect(x: frame.midX - 3.5, y: frame.maxY - 3.5, width: 7, height: 1.5)
                    compactLabelColor.withAlphaComponent(strength * 0.68).setFill()
                    NSBezierPath(roundedRect: marker, xRadius: 0.75, yRadius: 0.75).fill()
                }
            } else {
                let borderColor = isDarkMode ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.09)
                borderColor.setStroke()
                keyPath.lineWidth = 0.8
                keyPath.stroke()
                drawKeyLegend(for: key, in: frame, scale: metrics.scale, textColor: labelColor)
                drawCountBadge(for: count, in: frame, scale: metrics.scale, isDarkMode: isDarkMode)
            }
        }

        if let constellation {
            drawConstellation(constellation, metrics: metrics, palette: palette, isDark: isDarkMode)
            // Keep the legends on top of any lines that pass through neighboring keys.
            for key in Self.layout {
                guard let textColor = constellationLabelColors[key.id] else { continue }
                let frame = keyFrame(for: key.frameUnits, metrics: metrics)
                drawCompactLegend(for: key, in: frame, scale: metrics.scale, textColor: textColor)
            }
        }
    }

    private static func layoutBounds() -> CGRect {
        Self.layout.reduce(into: CGRect.null) { partialResult, key in
            partialResult = partialResult.union(key.frameUnits)
        }
    }

    private func renderMetrics() -> RenderMetrics? {
        guard !Self.layout.isEmpty else { return nil }

        let inset = isCompact ? 1 : Self.layoutContentInset
        let availableBounds = bounds.insetBy(dx: inset, dy: inset)
        guard availableBounds.width > 0, availableBounds.height > 0 else { return nil }

        let layoutBounds = Self.layoutBounds()
        let scaleX = availableBounds.width / layoutBounds.width
        let scaleY = availableBounds.height / layoutBounds.height
        let scale = min(scaleX, scaleY, Self.maximumKeyboardScale)
        let actualSize = CGSize(width: layoutBounds.width * scale, height: layoutBounds.height * scale)
        let origin = CGPoint(
            x: availableBounds.midX - actualSize.width / 2 - layoutBounds.minX * scale,
            y: availableBounds.midY - actualSize.height / 2 - layoutBounds.minY * scale
        )
        return RenderMetrics(scale: scale, origin: origin, layoutBounds: layoutBounds)
    }

    private func keyFrame(for units: CGRect, metrics: RenderMetrics) -> CGRect {
        CGRect(
            x: metrics.origin.x + units.minX * metrics.scale,
            y: metrics.origin.y + units.minY * metrics.scale,
            width: units.width * metrics.scale,
            height: units.height * metrics.scale
        )
    }

    private func drawConstellation(_ frame: KeyboardHeatmapEffects.Constellation, metrics: RenderMetrics,
                                   palette: [NSColor], isDark: Bool) {
        let tint = isDark ? (palette[1].blended(withFraction: 0.36, of: .white) ?? palette[1]) : palette[4]
        let backdrop: NSColor = isDark ? .black : .white

        func point(in cap: CGRect) -> CGPoint {
            CGPoint(x: cap.minX + min(6.5, cap.width * 0.28), y: cap.minY + min(6.5, cap.height * 0.4))
        }

        let lines = NSBezierPath()
        lines.lineCapStyle = .round
        var drawingTip: CGPoint?
        for link in frame.links {
            guard let from = Self.positions[link.from], let to = Self.positions[link.to] else { continue }
            let start = point(in: keyFrame(for: from, metrics: metrics))
            let end = point(in: keyFrame(for: to, metrics: metrics))
            lines.move(to: start)
            let tip = CGPoint(x: start.x + (end.x - start.x) * link.progress,
                              y: start.y + (end.y - start.y) * link.progress)
            lines.line(to: tip)
            if link.progress < 1 { drawingTip = tip }
        }
        backdrop.withAlphaComponent(frame.opacity * 0.54).setStroke()
        lines.lineWidth = 2.7
        lines.stroke()
        tint.withAlphaComponent(frame.opacity * 0.86).setStroke()
        lines.lineWidth = 1.15
        lines.stroke()

        if let tip = drawingTip {
            let dot = NSBezierPath(ovalIn: NSRect(x: tip.x - 2, y: tip.y - 2, width: 4, height: 4))
            backdrop.withAlphaComponent(frame.opacity * 0.8).setStroke()
            dot.lineWidth = 1
            dot.stroke()
            tint.withAlphaComponent(frame.opacity).setFill()
            dot.fill()
        }

        for (key, state) in frame.stars {
            guard let units = Self.positions[key] else { continue }
            let cap = keyFrame(for: units, metrics: metrics)
            let center = point(in: cap)
            let pulseOpacity = frame.opacity * state.arrivalPulse
            if pulseOpacity > 0 {
                let outline = NSBezierPath(roundedRect: cap.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
                backdrop.withAlphaComponent(pulseOpacity * 0.8).setStroke()
                outline.lineWidth = 2.8
                outline.stroke()
                (isDark ? NSColor.white : tint).withAlphaComponent(pulseOpacity).setStroke()
                outline.lineWidth = 1.45
                outline.stroke()
            }

            let opacity = frame.opacity * state.brightness
            let radius = min(4.3, metrics.scale * 0.16) * (0.8 + 0.2 * state.brightness + 0.22 * state.arrivalPulse)
            let haloRadius = radius + 2
            let halo = NSBezierPath(ovalIn: NSRect(x: center.x - haloRadius, y: center.y - haloRadius,
                                                  width: haloRadius * 2, height: haloRadius * 2))
            backdrop.withAlphaComponent(opacity * 0.72).setFill()
            halo.fill()
            tint.withAlphaComponent(opacity * 0.62).setStroke()
            halo.lineWidth = 0.75
            halo.stroke()

            let star = NSBezierPath()
            for index in 0..<8 {
                let angle = CGFloat(index) * .pi / 4
                let distance = index.isMultiple(of: 2) ? radius : radius * 0.38
                let vertex = CGPoint(x: center.x + sin(angle) * distance, y: center.y - cos(angle) * distance)
                if index == 0 { star.move(to: vertex) } else { star.line(to: vertex) }
            }
            star.close()
            tint.withAlphaComponent(opacity).setFill()
            star.fill()
        }
    }

    private func drawCompactLegend(for key: KeySpec, in frame: CGRect, scale: CGFloat, textColor: NSColor) {
        let symbol = key.symbolName.flatMap { Self.compactSymbols[$0] }
        let legend = symbol ?? (key.label.isEmpty ? "⎵" : key.label)
        let lines = legend.components(separatedBy: "\n")
        let hasShiftSymbol = lines.count > 1
        var textFrame = frame
        if hasShiftSymbol {
            // Leave room for the effect marker below the two glyphs.
            textFrame.origin.y += min(1.5, frame.height * 0.06)
            textFrame.size.height = frame.maxY - min(4.5, frame.height * 0.17) - textFrame.minY
        }
        let pointSize = hasShiftSymbol
            ? min(10, scale * 0.34, textFrame.height * 0.42)
            : min(12, scale * 0.34, textFrame.height * 0.68)
        let font = NSFont.systemFont(ofSize: pointSize, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let sizes = lines.map { $0.size(withAttributes: attributes) }
        let height = sizes.reduce(CGFloat.zero) { $0 + $1.height }
        var y = textFrame.midY - height / 2
        for (line, size) in zip(lines, sizes) {
            line.draw(at: NSPoint(x: textFrame.midX - size.width / 2, y: y), withAttributes: attributes)
            y += size.height
        }
    }

    private func compactLevel(for count: Int) -> Int {
        guard count > 0, maxCount > 0 else { return 0 }
        let weight = sqrt(Double(count) / Double(maxCount))
        return min(4, Int(ceil(weight * 4)))
    }

    private static func compactLabelColor(on fill: NSColor) -> NSColor {
        func linearComponent(_ component: CGFloat) -> CGFloat {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linearComponent(fill.redComponent)
            + 0.7152 * linearComponent(fill.greenComponent) + 0.0722 * linearComponent(fill.blueComponent)
        return luminance < 0.179 ? .white : .black
    }

    private func drawKeyLegend(for key: KeySpec, in frame: CGRect, scale: CGFloat, textColor: NSColor) {
        if let symbolName = key.symbolName {
            drawSymbolLegend(for: key, symbolName: symbolName, in: frame, scale: scale, textColor: textColor)
            return
        }

        guard !key.label.isEmpty else { return }

        if key.label.contains("\n") {
            drawDualLineLegend(for: key, in: frame, scale: scale, textColor: textColor)
            return
        }

        let font = NSFont.systemFont(ofSize: max(9, min(13, scale * 0.28)), weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let size = key.label.size(withAttributes: attributes)

        let horizontalInset = max(4, scale * 0.16)
        let verticalInset = max(3, scale * 0.14)
        let point = CGPoint(
            x: frame.maxX - size.width - horizontalInset,
            y: frame.maxY - size.height - verticalInset
        )

        key.label.draw(at: point, withAttributes: attributes)
    }

    private func drawSymbolLegend(for key: KeySpec, symbolName: String, in frame: CGRect, scale: CGFloat, textColor: NSColor) {
        let symbolPointSize = max(10, min(15, scale * 0.30))
        let symbolWeight: NSFont.Weight = key.id.contains("Shift") ? .semibold : .medium
        let horizontalInset = max(4, scale * 0.14)
        let bottomInset = max(3, scale * 0.12)
        let symbolRect = CGRect(
            x: frame.maxX - symbolPointSize * 1.04 - horizontalInset,
            y: frame.maxY - symbolPointSize * 1.04 - bottomInset,
            width: symbolPointSize * 1.04,
            height: symbolPointSize * 1.04
        )

        if let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: symbolWeight)) {
            symbolImage.draw(in: symbolRect)
        }

        guard !key.label.isEmpty else { return }

        let labelFont = NSFont.systemFont(ofSize: max(7.5, min(9.5, scale * 0.19)), weight: .medium)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: textColor.withAlphaComponent(0.86)
        ]
        let labelSize = key.label.size(withAttributes: labelAttributes)
        let labelBottomGap = max(2, scale * 0.08)
        let labelPoint = CGPoint(
            x: frame.maxX - labelSize.width - horizontalInset,
            y: max(frame.minY + 2, symbolRect.minY - labelSize.height - labelBottomGap)
        )
        key.label.draw(at: labelPoint, withAttributes: labelAttributes)
    }

    private func drawDualLineLegend(for key: KeySpec, in frame: CGRect, scale: CGFloat, textColor: NSColor) {
        let components = key.label
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard components.count == 2 else { return }

        let upper = components[0]
        let lower = components[1]

        let upperFont = NSFont.systemFont(ofSize: max(8, min(11, scale * 0.23)), weight: .regular)
        let lowerFont = NSFont.systemFont(ofSize: max(9.5, min(13, scale * 0.28)), weight: .medium)
        let upperAttributes: [NSAttributedString.Key: Any] = [
            .font: upperFont,
            .foregroundColor: textColor.withAlphaComponent(0.84)
        ]
        let lowerAttributes: [NSAttributedString.Key: Any] = [
            .font: lowerFont,
            .foregroundColor: textColor
        ]

        let upperSize = upper.size(withAttributes: upperAttributes)
        let lowerSize = lower.size(withAttributes: lowerAttributes)
        let horizontalInset = max(4, scale * 0.16)
        let bottomInset = max(2.5, scale * 0.11)
        let lineSpacing = max(1.5, scale * 0.05)

        let lowerPoint = CGPoint(
            x: frame.maxX - lowerSize.width - horizontalInset,
            y: frame.maxY - lowerSize.height - bottomInset
        )

        if Self.numberKeyIDs.contains(key.id) {
            lower.draw(at: lowerPoint, withAttributes: lowerAttributes)
            return
        }

        let upperPoint = CGPoint(
            x: frame.maxX - upperSize.width - horizontalInset,
            y: max(frame.minY + 2, lowerPoint.y - upperSize.height - lineSpacing)
        )

        upper.draw(at: upperPoint, withAttributes: upperAttributes)
        lower.draw(at: lowerPoint, withAttributes: lowerAttributes)
    }

    private func count(for key: KeySpec) -> Int {
        if let direct = keyCounts[key.id] {
            return direct
        }

        for fallbackID in key.fallbackCountIDs {
            if let fallbackCount = keyCounts[fallbackID] {
                return fallbackCount
            }
        }

        return 0
    }

    private func drawCountBadge(for count: Int, in frame: CGRect, scale: CGFloat, isDarkMode: Bool) {
        guard count > 0 else { return }

        let inset = max(3, scale * 0.08)
        let horizontalPadding = max(4, scale * 0.10)
        let verticalPadding = max(1.5, scale * 0.05)
        let maxBadgeWidth = max(14, frame.width - inset * 2)
        guard maxBadgeWidth > 10 else { return }

        let font = NSFont.monospacedDigitSystemFont(ofSize: max(7, min(10.5, scale * 0.20)), weight: .semibold)
        let textColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.95)
            : NSColor(calibratedWhite: 0.12, alpha: 0.95)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]

        var text = toolTipCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
        let fullTextWidth = text.size(withAttributes: attributes).width + horizontalPadding * 2
        if fullTextWidth > maxBadgeWidth {
            text = compactCountText(for: count)
        }

        var textSize = text.size(withAttributes: attributes)
        let badgeHeight = max(max(12, scale * 0.30), textSize.height + verticalPadding * 2)
        var badgeWidth = max(badgeHeight, textSize.width + horizontalPadding * 2)
        if badgeWidth > maxBadgeWidth {
            badgeWidth = maxBadgeWidth
            text = compactCountText(for: count, maximumLength: 3)
            textSize = text.size(withAttributes: attributes)
        }

        let badgeRect = CGRect(
            x: frame.minX + inset,
            y: frame.minY + inset,
            width: badgeWidth,
            height: badgeHeight
        )

        let badgePath = NSBezierPath(
            roundedRect: badgeRect,
            xRadius: badgeHeight * 0.5,
            yRadius: badgeHeight * 0.5
        )
        let backgroundColor = isDarkMode
            ? NSColor.black.withAlphaComponent(0.38)
            : NSColor.white.withAlphaComponent(0.84)
        backgroundColor.setFill()
        badgePath.fill()

        let borderColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.22)
            : NSColor.black.withAlphaComponent(0.14)
        borderColor.setStroke()
        badgePath.lineWidth = 0.7
        badgePath.stroke()

        let textPoint = CGPoint(
            x: badgeRect.minX + (badgeRect.width - textSize.width) / 2,
            y: badgeRect.minY + (badgeRect.height - textSize.height) / 2 + font.descender * 0.45
        )
        text.draw(at: textPoint, withAttributes: attributes)
    }

    private func compactCountText(for count: Int, maximumLength: Int = 4) -> String {
        let compact: String
        if count >= 1_000_000_000 {
            compact = compactUnit(Double(count) / 1_000_000_000, suffix: "B")
        } else if count >= 1_000_000 {
            compact = compactUnit(Double(count) / 1_000_000, suffix: "M")
        } else if count >= 1_000 {
            compact = compactUnit(Double(count) / 1_000, suffix: "K")
        } else {
            compact = "\(count)"
        }

        if compact.count <= maximumLength {
            return compact
        }

        if count >= 1_000_000_000 {
            return "\(Int(round(Double(count) / 1_000_000_000)))B"
        }
        if count >= 1_000_000 {
            return "\(Int(round(Double(count) / 1_000_000)))M"
        }
        if count >= 1_000 {
            return "\(Int(round(Double(count) / 1_000)))K"
        }
        return compact
    }

    private func compactUnit(_ value: Double, suffix: String) -> String {
        let rounded = (value * 10).rounded() / 10
        let numberText: String
        if abs(rounded.rounded() - rounded) < 0.05 {
            numberText = "\(Int(rounded.rounded()))"
        } else {
            numberText = String(format: "%.1f", rounded)
        }
        return "\(numberText)\(suffix)"
    }

    private func color(for count: Int, isDarkMode: Bool) -> NSColor {
        let surfaceColor = isDarkMode ? NSColor.windowBackgroundColor : NSColor.controlBackgroundColor
        let neutralColor = surfaceColor.blended(withFraction: isDarkMode ? 0.22 : 0.10, of: .separatorColor)
            ?? (isDarkMode
                ? NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.25, alpha: 1)
                : NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.96, alpha: 1))

        if count <= 0 {
            return neutralColor
        }

        let normalized = maxCount > 0
            ? CGFloat(log(Double(count) + 1) / log(Double(maxCount) + 1))
            : 0
        let eased = pow(normalized, 0.82)

        let accentColor = NSColor.controlAccentColor
        let lowColor = neutralColor.blended(withFraction: isDarkMode ? 0.34 : 0.24, of: accentColor)
            ?? blendColor(from: neutralColor, to: accentColor, t: isDarkMode ? 0.34 : 0.24)
        let highColor = accentColor.blended(withFraction: isDarkMode ? 0.18 : 0.10, of: isDarkMode ? .white : .black)
            ?? blendColor(from: accentColor, to: isDarkMode ? .white : .black, t: isDarkMode ? 0.18 : 0.10)

        return blendColor(from: lowColor, to: highColor, t: eased)
    }

    private func blendColor(from: NSColor, to: NSColor, t: CGFloat) -> NSColor {
        let progress = max(0, min(1, t))
        let fromRGB = from.usingColorSpace(.deviceRGB) ?? from
        let toRGB = to.usingColorSpace(.deviceRGB) ?? to

        let red = fromRGB.redComponent + (toRGB.redComponent - fromRGB.redComponent) * progress
        let green = fromRGB.greenComponent + (toRGB.greenComponent - fromRGB.greenComponent) * progress
        let blue = fromRGB.blueComponent + (toRGB.blueComponent - fromRGB.blueComponent) * progress
        let alpha = fromRGB.alphaComponent + (toRGB.alphaComponent - fromRGB.alphaComponent) * progress

        return NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}
