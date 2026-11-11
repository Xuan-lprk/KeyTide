import AppKit

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

func statsResolvedCGColor(_ color: NSColor, for view: NSView) -> CGColor {
    var resolved = color.cgColor
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        resolved = color.cgColor
    }
    return resolved
}

func statsResolvedColor(_ color: NSColor, for view: NSView) -> NSColor {
    NSColor(cgColor: statsResolvedCGColor(color, for: view)) ?? color
}

final class AppearanceTrackingView: NSView {
    var onEffectiveAppearanceChange: (() -> Void)?
    private var appearanceChangeToken = UUID()

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChangeToken = UUID()
        let token = appearanceChangeToken
        for delay in [0.0, 0.05, 0.15, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.appearanceChangeToken == token else { return }
                self.onEffectiveAppearanceChange?()
            }
        }
    }
}

final class StatsPanelView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = statsResolvedCGColor(.controlBackgroundColor, for: self)
        layer?.borderColor = statsResolvedCGColor(.separatorColor, for: self)
        layer?.shadowOpacity = 0
    }
}

final class StatsSeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = statsResolvedCGColor(.separatorColor, for: self)
    }
}

final class StatsMetricView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "—")
    private let marker = NSView()
    private let markerColor: NSColor

    init(title: String, color: NSColor) {
        markerColor = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        marker.wantsLayer = true
        marker.layer?.backgroundColor = statsResolvedCGColor(color, for: self)
        marker.layer?.cornerRadius = 1.5
        marker.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.toolTip = title

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .medium)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, valueLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 5
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(marker)
        addSubview(textStack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),
            marker.leadingAnchor.constraint(equalTo: leadingAnchor),
            marker.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            marker.widthAnchor.constraint(equalToConstant: 3),
            marker.heightAnchor.constraint(equalToConstant: 30),
            textStack.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setValue(_ value: String) {
        valueLabel.stringValue = value
        toolTip = value
        setAccessibilityValue(value)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        marker.layer?.backgroundColor = statsResolvedCGColor(markerColor, for: self)
    }
}

enum StatsWindowStyle {
    static func title(_ key: String) -> NSTextField {
        let label = NSTextField(labelWithString: NSLocalizedString(key, comment: ""))
        label.font = .systemFont(ofSize: 26, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    static func sectionTitle(_ key: String) -> NSTextField {
        let label = NSTextField(labelWithString: NSLocalizedString(key, comment: ""))
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    static func secondaryLabel(_ text: String = "", wrapping: Bool = false) -> NSTextField {
        let label = wrapping ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    static func separator() -> NSView {
        let line = StatsSeparatorView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return line
    }

    static func fullWidth(_ child: NSView, in stack: NSStackView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -stack.edgeInsets.left - stack.edgeInsets.right).isActive = true
    }
}
