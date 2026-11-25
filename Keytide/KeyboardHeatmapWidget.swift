import Cocoa

final class KeyboardHeatmapWidget: NSView {
    typealias Pattern = KeyboardHeatmapEffects.Constellation.NamedGroup.Pattern
    static let contentHeight: CGFloat = 278
    private static let sparkleImage = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
    private static let geminiImage = NSImage(named: "GeminiSpark")

    private let heatmap: KeyboardHeatmapView
    private let effect: KeyboardHeatmapEffect
    private let playButton = NSButton()
    private var effectTimer: Timer?
    private var effectFrames: [KeyboardHeatmapEffects.Frame] = []
    private var effectStart: TimeInterval = 0
    private let countLabel = NSTextField(labelWithString: "")
    private let constellationCaption = NSTextField(labelWithString: "")
    private let constellationSymbol = NSImageView()
    private let constellationOriginalCaption = NSTextField(labelWithString: "")
    private let constellationNames = NSStackView()
    private var lastKeyCounts: [String: Int]?
    private var isPresented = false
    private(set) var lastConstellationPatterns: Set<Pattern>

    init(theme: KeyboardHeatmapTheme, effect: KeyboardHeatmapEffect, previousPatterns: Set<Pattern> = []) {
        heatmap = KeyboardHeatmapView(isCompact: true, theme: theme)
        self.effect = effect
        lastConstellationPatterns = previousPatterns
        super.init(frame: .zero)
        configureContent(theme: theme)
        if effect != .still {
            heatmap.onActivateKey = { [weak self] key in self?.playEffect(from: key) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateEffectAvailability),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        effectTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func start(previewGemini: Bool = false) {
        guard !isPresented else { return }
        isPresented = true
        if previewGemini { showGeminiPreview() }
        else { playEffect() }
    }

    func stop() {
        isPresented = false
        stopEffect()
    }

    func refresh(_ stats: DailyStats) {
        if lastKeyCounts != stats.keyPressCounts {
            lastKeyCounts = stats.keyPressCounts
            heatmap.apply(keyCounts: keyboardHeatmapCounts(from: stats.keyPressCounts))
        }
        let caption = stats.keyPresses > 0
            ? String(format: NSLocalizedString("menuHeatmap.todayCount", comment: ""), stats.keyPresses.formatted())
            : NSLocalizedString("keyboardHeatmap.noData", comment: "")
        if countLabel.stringValue != caption { countLabel.stringValue = caption }
    }

    @objc private func replayEffect() { playEffect() }

    @objc private func updateEffectAvailability() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        playButton.isHidden = effect == .still || reduceMotion
        if reduceMotion { stopEffect() }
    }

    private func playEffect(from key: String? = nil) {
        guard effect != .still, isPresented, window?.isVisible == true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let frames = heatmap.frames(for: effect, from: key, avoiding: lastConstellationPatterns)
        play(frames, interval: effect.frameInterval)
    }

    private func showGeminiPreview() {
        let frames = heatmap.geminiPreviewFrames()
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            play(frames, interval: KeyboardHeatmapEffect.constellation.frameInterval)
            return
        }
        for case let .constellation(state) in frames where state.geminiWash == 1 {
            prepareConstellation(state)
            constellationNames.alphaValue = state.opacity
            heatmap.showEffectFrame(.constellation(state))
            return
        }
    }

    private func play(_ frames: [KeyboardHeatmapEffects.Frame], interval: TimeInterval) {
        stopEffect()
        guard let first = frames.first else { return }
        effectFrames = frames
        if case .constellation(let constellation) = first {
            prepareConstellation(constellation)
        }
        effectStart = ProcessInfo.processInfo.systemUptime
        advanceEffect(interval: interval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.advanceEffect(interval: interval)
        }
        effectTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceEffect(interval: TimeInterval) {
        let elapsed = ProcessInfo.processInfo.systemUptime - effectStart
        let index = Int(elapsed / interval)
        guard isPresented, window?.isVisible == true, effectFrames.indices.contains(index) else { stopEffect(); return }
        let frame = effectFrames[index]
        heatmap.showEffectFrame(frame)
        if case .constellation(let constellation) = frame {
            constellationNames.alphaValue = constellation.opacity
        }
    }

    private func prepareConstellation(_ state: KeyboardHeatmapEffects.Constellation) {
        lastConstellationPatterns = Set(state.namedGroups.map(\.pattern))
        showConstellationNames(state.namedGroups)
    }

    private func stopEffect() {
        effectTimer?.invalidate()
        effectTimer = nil
        effectFrames = []
        heatmap.showEffectFrame(nil)
        constellationNames.isHidden = true
    }

    private func showConstellationNames(_ groups: [KeyboardHeatmapEffects.Constellation.NamedGroup]) {
        let gemini = groups.contains { $0.pattern == .gemini } ? Self.geminiImage : nil
        constellationSymbol.image = gemini ?? Self.sparkleImage
        constellationSymbol.contentTintColor = gemini == nil ? .secondaryLabelColor : nil
        let counts = Dictionary(grouping: groups, by: \.pattern).mapValues(\.count)
        let keyedTitle = NSLocalizedString("menuHeatmap.constellation.name.withKey", comment: "")
        func nameList(_ title: (KeyboardHeatmapEffects.Constellation.NamedGroup.Pattern) -> String) -> String {
            groups.map { group in
                let name = title(group.pattern)
                return counts[group.pattern, default: 0] > 1 ? String(format: keyedTitle, name, group.firstKey) : name
            }.joined(separator: " · ")
        }
        constellationCaption.stringValue = nameList(\.title)
        constellationCaption.toolTip = constellationCaption.stringValue
        constellationOriginalCaption.stringValue = nameList(\.originalTitle)
        constellationOriginalCaption.toolTip = constellationOriginalCaption.stringValue
        constellationNames.isHidden = false
    }

    private func configureContent(theme: KeyboardHeatmapTheme) {
        let title = NSTextField(labelWithString: MenuWidgetKind.heatmap.title)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail

        let replay = NSLocalizedString("menuHeatmap.replayEffect", comment: "")
        playButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: replay)
        playButton.contentTintColor = .secondaryLabelColor
        playButton.isBordered = false
        playButton.imagePosition = .imageOnly
        playButton.target = self
        playButton.action = #selector(replayEffect)
        playButton.toolTip = replay
        playButton.setAccessibilityLabel(replay)
        updateEffectAvailability()

        let legend = NSStackView(views: [
            Self.legendLabel(key: "heatmap.less"), KeyboardHeatmapLegend(theme: theme), Self.legendLabel(key: "heatmap.more")
        ])
        legend.alignment = .centerY
        legend.spacing = 7

        constellationCaption.font = .systemFont(ofSize: 11, weight: .medium)
        constellationOriginalCaption.font = .systemFont(ofSize: 10.5, weight: .medium)
        constellationOriginalCaption.textColor = .secondaryLabelColor
        for caption in [constellationCaption, constellationOriginalCaption] {
            caption.lineBreakMode = .byTruncatingTail
            caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        constellationSymbol.imageScaling = .scaleProportionallyUpOrDown
        constellationSymbol.setAccessibilityElement(false)
        constellationNames.alignment = .centerY
        constellationNames.spacing = 7
        for subview in [constellationCaption, constellationSymbol, constellationOriginalCaption] {
            constellationNames.addArrangedSubview(subview)
        }
        constellationNames.isHidden = true

        for subview in [title, countLabel, heatmap, legend, constellationNames, playButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            countLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            countLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            heatmap.leadingAnchor.constraint(equalTo: leadingAnchor),
            heatmap.trailingAnchor.constraint(equalTo: trailingAnchor),
            heatmap.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 10),
            heatmap.bottomAnchor.constraint(equalTo: legend.topAnchor, constant: -8),
            legend.leadingAnchor.constraint(equalTo: leadingAnchor),
            legend.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            playButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            playButton.centerYAnchor.constraint(equalTo: legend.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 26),
            playButton.heightAnchor.constraint(equalToConstant: 26),
            constellationNames.centerXAnchor.constraint(equalTo: heatmap.centerXAnchor),
            constellationNames.leadingAnchor.constraint(greaterThanOrEqualTo: legend.trailingAnchor, constant: 8),
            constellationNames.trailingAnchor.constraint(lessThanOrEqualTo: playButton.leadingAnchor, constant: -8),
            constellationNames.centerYAnchor.constraint(equalTo: legend.centerYAnchor),
            constellationSymbol.widthAnchor.constraint(equalToConstant: 13),
            constellationSymbol.heightAnchor.constraint(equalToConstant: 13)
        ])
    }

    private static func legendLabel(key: String) -> NSTextField {
        let label = NSTextField(labelWithString: NSLocalizedString(key, comment: ""))
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }
}

private final class KeyboardHeatmapLegend: NSView {
    private let theme: KeyboardHeatmapTheme

    init(theme: KeyboardHeatmapTheme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 63, height: 9) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for (level, color) in theme.palette(isDark: dark).enumerated() {
            let rect = NSRect(x: CGFloat(level) * 13, y: 0, width: 10, height: 9)
            let swatch = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            color.setFill()
            swatch.fill()
        }
    }
}
