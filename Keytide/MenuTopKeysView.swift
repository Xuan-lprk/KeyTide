import AppKit

/// A ranked view of today's aggregate key counts, including shortcuts.
final class MenuTopKeysView: NSView {
    static let cardHeight: CGFloat = 190

    private let style: MenuWidget.Style
    private let cells: [KeyCell]
    private let emptyLabel = NSTextField(labelWithString: NSLocalizedString("keyBreakdown.empty", comment: ""))
    private var lastCounts: [String: Int]?
    private var visibleCount = 0

    init(style: MenuWidget.Style) {
        self.style = style
        cells = (1...15).map { KeyCell(style: style, rank: $0) }
        super.init(frame: .zero)

        for cell in cells {
            cell.isHidden = true
            addSubview(cell)
        }
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = style == .geek ? GeekPalette.secondary : .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func update(counts: [String: Int]) {
        guard counts != lastCounts else { return }
        lastCounts = counts

        let ranked = keyBreakdownDisplayCounts(from: counts).sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }
        let peak = ranked.first?.value ?? 1
        let nextCount = min(ranked.count, cells.count)
        for (cell, entry) in zip(cells, ranked) {
            cell.update(key: entry.key, count: entry.value, strength: CGFloat(entry.value) / CGFloat(peak))
            cell.isHidden = false
        }
        if nextCount != visibleCount {
            cells.dropFirst(nextCount).forEach { $0.isHidden = true }
            visibleCount = nextCount
            emptyLabel.isHidden = nextCount > 0
            needsLayout = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize { needsLayout = true }
        super.setFrameSize(newSize)
    }

    override func layout() {
        super.layout()
        guard visibleCount > 0 else { return }
        let geek = style == .geek
        let columns = geek ? 3 : 5
        let columnGap: CGFloat = geek ? 16 : 6
        let rowGap: CGFloat = geek ? 2 : 6
        let maximumRows = geek ? 5 : 3
        let rowHeight = min(geek ? 27 : 44, floor((bounds.height - CGFloat(maximumRows - 1) * rowGap) / CGFloat(maximumRows)))
        let columnWidth = floor((bounds.width - CGFloat(columns - 1) * columnGap) / CGFloat(columns))
        guard rowHeight > 0, columnWidth > 0 else { return }

        let rows = (visibleCount + columns - 1) / columns
        let usedColumns = geek ? (visibleCount + rows - 1) / rows : min(columns, visibleCount)
        let gridWidth = CGFloat(usedColumns) * (columnWidth + columnGap) - columnGap
        let gridHeight = CGFloat(rows) * (rowHeight + rowGap) - rowGap
        let x = floor((bounds.width - gridWidth) / 2)
        let y = floor((bounds.height - gridHeight) / 2)
        for (index, cell) in cells.prefix(visibleCount).enumerated() {
            let column = geek ? index / rows : index % columns
            let row = geek ? index % rows : index / columns
            cell.frame = NSRect(x: x + CGFloat(column) * (columnWidth + columnGap),
                                y: y + CGFloat(row) * (rowHeight + rowGap),
                                width: columnWidth, height: rowHeight)
        }
    }

    private final class KeyCell: NSView {
        private static let glyphs = [
            "Cmd": "⌘", "Option": "⌥", "Shift": "⇧", "Ctrl": "⌃", "LeftCtrl": "⌃", "RightCtrl": "⌃",
            "Return": "↩", "Tab": "⇥", "Delete": "⌫", "Backspace": "⌫", "ForwardDelete": "⌦", "Esc": "⎋",
            "Left": "←", "Right": "→", "Up": "↑", "Down": "↓"
        ]

        private let style: MenuWidget.Style
        private let rankLabel = NSTextField(labelWithString: "")
        private let keyLabel = NSTextField(labelWithString: "")
        private let countLabel = NSTextField(labelWithString: "")
        private var key = ""
        private var count = 0
        private var exactCount = ""
        private var strength: CGFloat = 0

        init(style: MenuWidget.Style, rank: Int) {
            self.style = style
            super.init(frame: .zero)

            let geek = style == .geek
            if geek {
                rankLabel.stringValue = String(format: "%02d", rank)
                rankLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
                rankLabel.textColor = rank == 1 ? GeekPalette.cyan : GeekPalette.secondary
                rankLabel.setAccessibilityElement(false)
                addSubview(rankLabel)
            }
            keyLabel.textColor = geek ? GeekPalette.text : .secondaryLabelColor
            keyLabel.lineBreakMode = .byTruncatingMiddle
            countLabel.textColor = geek ? GeekPalette.text : .labelColor
            countLabel.alignment = geek ? .right : .left
            countLabel.lineBreakMode = .byTruncatingTail
            for label in [keyLabel, countLabel] {
                label.setAccessibilityElement(false)
                addSubview(label)
            }
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var isFlipped: Bool { true }

        func update(key: String, count: Int, strength: CGFloat) {
            guard key != self.key || count != self.count || strength != self.strength else { return }
            if key != self.key {
                self.key = key
                var parts = key.split(separator: "+").map { Self.glyphs[String($0)] ?? String($0) }
                if key.hasSuffix("+") { parts.append("+") }
                keyLabel.stringValue = parts.joined(separator: "\u{200A}")
                setAccessibilityLabel(AppKeyBreakdown.displayKey(key))
                needsLayout = true
            }
            if count != self.count {
                self.count = count
                exactCount = count.formatted()
                setAccessibilityValue(exactCount)
                needsLayout = true
            }
            toolTip = "\(AppKeyBreakdown.displayKey(key)) · \(exactCount)"
            self.strength = strength
            needsDisplay = true
        }

        override func setFrameSize(_ newSize: NSSize) {
            if frame.size != newSize { needsLayout = true }
            super.setFrameSize(newSize)
        }

        override func layout() {
            super.layout()
            let geek = style == .geek
            let available = max(0, bounds.width - 2 * padding)
            let rankWidth: CGFloat = geek && available >= 106 ? 20 : 0
            let countLimit = geek ? min(available * 0.58, max(0, available - rankWidth - 30)) : available
            let countSize: CGFloat = geek ? 12 : (available < 48 ? 13 : 15)
            countLabel.font = .monospacedDigitSystemFont(ofSize: countSize, weight: .semibold)
            countLabel.stringValue = exactCount
            if labelWidth(countLabel) > countLimit {
                countLabel.stringValue = formatMenuBarCompactNumber(count)
                if labelWidth(countLabel) > countLimit {
                    countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
                }
            }

            if geek {
                let countWidth = min(countLimit, labelWidth(countLabel))
                rankLabel.isHidden = rankWidth == 0
                rankLabel.frame = NSRect(x: padding, y: 3, width: rankWidth, height: 14)
                keyLabel.frame = NSRect(x: padding + rankWidth, y: 2, width: max(0, available - rankWidth - countWidth - 6), height: 16)
                countLabel.frame = NSRect(x: bounds.width - padding - countWidth, y: 2, width: countWidth, height: 16)
            } else {
                keyLabel.frame = NSRect(x: padding, y: 4, width: available, height: 16)
                countLabel.frame = NSRect(x: padding, y: 18, width: available, height: 18)
            }
            keyLabel.font = geek ? .monospacedSystemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 12, weight: .medium)
            if labelWidth(keyLabel) > keyLabel.frame.width {
                keyLabel.font = geek ? .monospacedSystemFont(ofSize: 10, weight: .semibold) : .systemFont(ofSize: 10, weight: .medium)
            }
        }

        private var padding: CGFloat {
            if style == .geek { return 2 }
            return bounds.width < 65 ? 4 : 8
        }

        private func labelWidth(_ label: NSTextField) -> CGFloat {
            ceil(label.cell?.cellSize.width ?? 0) + 4
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let geek = style == .geek
            let accent = geek ? GeekPalette.cyan : NSColor.controlAccentColor
            if !geek {
                let tile = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
                NSColor.labelColor.withAlphaComponent(0.045).setFill()
                tile.fill()
                accent.withAlphaComponent(strength * 0.12).setFill()
                tile.fill()
            }

            let track = NSRect(x: padding, y: bounds.height - (geek ? 4 : 6), width: max(0, bounds.width - 2 * padding), height: 2)
            let trackColor = geek ? GeekPalette.grid.withAlphaComponent(0.65) : NSColor.labelColor.withAlphaComponent(0.075)
            trackColor.setFill()
            NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
            var bar = track
            bar.size.width = min(track.width, max(2, track.width * strength))
            accent.withAlphaComponent(geek ? 0.45 + strength * 0.5 : 0.45 + strength * 0.3).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        }
    }
}
