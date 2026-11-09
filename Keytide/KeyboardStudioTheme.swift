import Cocoa
import QuartzCore
import CoreGraphics

struct KeyboardStudioPalette {
    let background: NSColor
    let glow: NSColor
    let text: NSColor
    let secondary: NSColor
    let accent: NSColor
    let panel: NSColor
    let line: NSColor
    let grid: NSColor

    init(style: MenuUIStyle) {
        if style == .geek {
            background = NSColor(srgbRed: 0.025, green: 0.039, blue: 0.047, alpha: 1)
            glow = NSColor(srgbRed: 0.025, green: 0.12, blue: 0.14, alpha: 1)
            text = NSColor(srgbRed: 0.82, green: 0.94, blue: 0.93, alpha: 1)
            secondary = NSColor(srgbRed: 0.37, green: 0.58, blue: 0.60, alpha: 1)
            accent = NSColor(srgbRed: 0.25, green: 0.87, blue: 0.82, alpha: 1)
            panel = NSColor(srgbRed: 0.035, green: 0.060, blue: 0.070, alpha: 0.96)
            line = NSColor(srgbRed: 0.20, green: 0.46, blue: 0.47, alpha: 0.48)
            grid = NSColor(srgbRed: 0.18, green: 0.46, blue: 0.45, alpha: 0.10)
        } else {
            background = NSColor(srgbRed: 0.050, green: 0.061, blue: 0.072, alpha: 1)
            glow = NSColor(srgbRed: 0.15, green: 0.19, blue: 0.23, alpha: 1)
            text = NSColor(srgbRed: 0.94, green: 0.95, blue: 0.94, alpha: 1)
            secondary = NSColor(srgbRed: 0.53, green: 0.59, blue: 0.64, alpha: 1)
            accent = NSColor(srgbRed: 0.55, green: 0.72, blue: 0.90, alpha: 1)
            panel = NSColor(srgbRed: 0.085, green: 0.105, blue: 0.125, alpha: 0.96)
            line = NSColor.white.withAlphaComponent(0.13)
            grid = .clear
        }
    }
}

/// A static stage: atmosphere lives behind the keyboard, never in its render loop.
final class KeyboardStudioStageView: NSView {
    var onBackgroundClick: (() -> Void)?
    var style: MenuUIStyle = .standard { didSet { needsDisplay = true } }
    var palette: KeyboardStudioPalette { KeyboardStudioPalette(style: style) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) { onBackgroundClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let p = palette
        p.background.setFill(); bounds.fill()
        if let context = NSGraphicsContext.current?.cgContext,
           let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: [p.glow.cgColor, p.background.cgColor] as CFArray, locations: [0, 1]) {
            let center = CGPoint(x: bounds.midX, y: bounds.height * 0.62)
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                endCenter: center, endRadius: max(bounds.width, bounds.height) * 0.72, options: [])
        }
        guard style == .geek else { return }
        let path = NSBezierPath(); path.lineWidth = 0.5
        p.grid.setStroke()
        for x in stride(from: CGFloat(0), through: bounds.width, by: 28) {
            path.move(to: CGPoint(x: x, y: 0)); path.line(to: CGPoint(x: x, y: bounds.height))
        }
        for y in stride(from: CGFloat(0), through: bounds.height, by: 28) {
            path.move(to: CGPoint(x: 0, y: y)); path.line(to: CGPoint(x: bounds.width, y: y))
        }
        path.stroke()
    }
}

class KeyboardStudioPanel: NSView {
    var palette = KeyboardStudioPalette(style: .standard) {
        didSet { applyPalette() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        layer?.shadowOpacity = 0.24
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -5)
        applyPalette()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func applyPalette() {
        layer?.backgroundColor = palette.panel.cgColor
        layer?.borderColor = palette.line.cgColor
        layer?.shadowColor = NSColor.black.cgColor
    }
}

final class KeyboardKeyInsightCard: KeyboardStudioPanel {
    var onClose: (() -> Void)?
    private let key = keyboardStudioLabel("", size: 23, weight: .semibold)
    private let count = keyboardStudioLabel("", size: 19, weight: .medium)
    private let share = keyboardStudioLabel("", size: 19, weight: .medium)
    private let rank = keyboardStudioLabel("", size: 19, weight: .medium)
    private let close = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        close.bezelStyle = .inline; close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        close.target = self; close.action = #selector(closeCard)
        close.setAccessibilityLabel(NSLocalizedString("keyboard.insight.close", comment: "Keyboard Studio"))
        let heading = NSStackView(views: [key, keyboardStudioSpace(), close])
        heading.alignment = .centerY
        let metrics = keyboardStudioStack([
            keyboardStudioMetric("growth.key.count", count),
            keyboardStudioMetric("growth.key.share", share),
            keyboardStudioMetric("growth.key.position", rank)
        ], vertical: false, spacing: 24)
        let content = keyboardStudioStack([heading, metrics], vertical: true, spacing: 12)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            widthAnchor.constraint(equalToConstant: 310)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ selection: GrowthKeyboardSidebarSelection, palette: KeyboardStudioPalette) {
        self.palette = palette
        key.stringValue = selection.name
        count.stringValue = selection.count
        share.stringValue = String(format: "%.1f%%", selection.share * 100)
        rank.stringValue = selection.rank ?? NSLocalizedString("growth.key.unranked", comment: "")
        for label in [key, count, share, rank] { label.textColor = palette.text }
        for case let stack as NSStackView in subviews {
            tintLabels(in: stack, palette: palette)
        }
        close.contentTintColor = palette.secondary
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel(NSLocalizedString("growth.key.details", comment: ""))
        setAccessibilityValue(String(format: NSLocalizedString("growth.key.accessibility", comment: ""),
            selection.name, selection.countValue, selection.share * 100,
            selection.rank ?? NSLocalizedString("growth.key.unranked", comment: "")))
    }

    @objc private func closeCard() { onClose?() }
}

func keyboardStudioLabel(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular,
                         color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: value)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    return field
}

func keyboardStudioStack(_ views: [NSView], vertical: Bool, spacing: CGFloat) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = vertical ? .vertical : .horizontal
    stack.alignment = vertical ? .leading : .centerY
    stack.spacing = spacing
    return stack
}

func keyboardStudioSpace() -> NSView {
    let space = NSView()
    space.setContentHuggingPriority(.defaultLow, for: .horizontal)
    space.setContentHuggingPriority(.defaultLow, for: .vertical)
    return space
}

func keyboardStudioMetric(_ key: String, _ value: NSTextField) -> NSView {
    let caption = keyboardStudioLabel(NSLocalizedString(key, comment: "Keyboard Studio"), size: 9, weight: .medium)
    caption.setAccessibilityElement(false)
    return keyboardStudioStack([caption, value], vertical: true, spacing: 3)
}

func tintLabels(in view: NSView, palette: KeyboardStudioPalette) {
    if let label = view as? NSTextField, label.font?.pointSize ?? 0 <= 12 {
        label.textColor = palette.secondary
    }
    view.subviews.forEach { tintLabels(in: $0, palette: palette) }
}

/// A shareable image, not a screenshot of controls or private key-insight overlays.
enum KeyboardStudioImageExport {
    /// Writes only an explicitly requested image; never reads clipboard contents.
    static func copyPNG(_ data: Data, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let bitmap = NSBitmapImageRep(data: data), let tiff = bitmap.tiffRepresentation else { return false }
        let item = NSPasteboardItem()
        guard item.setData(data, forType: .png), item.setData(tiff, forType: .tiff) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    static let repository = "github.com/Xuan-lprk/KeyTide"

    static func png(keyboard: NSImage, model: String, mode: String, summary: String?,
                    coverage: String?, style: MenuUIStyle) -> Data? {
        let size = CGSize(width: 1280, height: 820)
        let p = KeyboardStudioPalette(style: style)
        let bitmap = KeyboardImageBitmap.make(size: size) {
            p.background.setFill()
            CGRect(origin: .zero, size: size).fill()
            if let context = NSGraphicsContext.current?.cgContext,
               let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [p.glow.cgColor, p.background.cgColor] as CFArray, locations: [0, 1]) {
                let center = CGPoint(x: 640, y: 370)
                context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                    endCenter: center, endRadius: 800, options: [])
            }
            func label(_ text: String, rect: CGRect, size: CGFloat, color: NSColor, bold: Bool = false) {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                (text as NSString).draw(in: rect, withAttributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                    .foregroundColor: color, .paragraphStyle: paragraph])
            }
            label("Keytide · \(model)", rect: CGRect(x: 44, y: 26, width: 1192, height: 32),
                  size: 23, color: p.text, bold: true)
            label(mode, rect: CGRect(x: 44, y: 64, width: 1192, height: 26), size: 14, color: p.accent)
            let area = CGRect(x: 24, y: 100, width: 1232, height: 560)
            let scale = min(area.width / keyboard.size.width, area.height / keyboard.size.height)
            let target = CGRect(x: area.midX - keyboard.size.width * scale / 2,
                y: area.midY - keyboard.size.height * scale / 2,
                width: keyboard.size.width * scale, height: keyboard.size.height * scale)
            keyboard.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            if let summary {
                label(summary, rect: CGRect(x: 44, y: 678, width: 1192, height: 26), size: 15, color: p.text)
                if let coverage {
                    label(coverage, rect: CGRect(x: 44, y: 710, width: 1192, height: 40), size: 12, color: p.secondary)
                }
            }
            p.line.setFill(); CGRect(x: 44, y: 764, width: 1192, height: 1).fill()
            label(repository, rect: CGRect(x: 44, y: 780, width: 1192, height: 22), size: 13, color: p.secondary)
        }
        return bitmap?.representation(using: .png, properties: [:])
    }
}
