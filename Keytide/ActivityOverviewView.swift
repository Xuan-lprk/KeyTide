import AppKit

/// Presentation-only daily chart. Values come from StatsManager's existing series;
/// selecting a day never changes the stored statistics or date range.
final class ActivityOverviewView: NSView {
    private var days: [ActivityHeatmapView.DayActivity] = []
    private var rects: [NSRect] = []
    private var hoveredIndex: Int?
    private var trackingArea: NSTrackingArea?
    private var windowObservers: [NSObjectProtocol] = []

    private(set) var selectedIndex: Int?
    var onSelectionChanged: ((Int) -> Void)?
    var onSelectionCleared: (() -> Void)?
    var onOpenDay: ((Int) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { !days.isEmpty }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if selectedIndex == nil, !days.isEmpty { selectDay(at: days.count - 1) }
        return true
    }

    func update(days: [ActivityHeatmapView.DayActivity], selectedDate: Date?) {
        self.days = days
        selectedIndex = selectedDate.flatMap { date in
            days.firstIndex { Calendar.current.isDate($0.date, inSameDayAs: date) }
        }
        hoveredIndex = nil
        updateAccessibility()
        needsLayout = true
        needsDisplay = true
    }

    func selectDay(at index: Int) {
        guard days.indices.contains(index) else { return }
        selectedIndex = index
        onSelectionChanged?(index)
        let selectedDate = days[index].date
        selectedIndex = days.firstIndex { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }
        updateAccessibility()
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func layout() {
        super.layout()
        rebuildRects()
    }

    private func rebuildRects() {
        rects.removeAll(keepingCapacity: true)
        guard !days.isEmpty, bounds.width > 0, bounds.height > 25 else { return }
        let slot = bounds.width / CGFloat(days.count)
        let maximum = max(1, days.reduce(0) { max($0, $1.total) })
        let maximumHeight = max(1, bounds.height - 31)
        for (index, day) in days.enumerated() {
            let height = day.total == 0 ? 2 : max(3, CGFloat(day.total) / CGFloat(maximum) * maximumHeight)
            let width = max(2, min(days.count > 14 ? 11 : 30, slot * 0.46))
            rects.append(NSRect(
                x: slot * CGFloat(index) + (slot - width) / 2,
                y: 5 + maximumHeight - height,
                width: width,
                height: height
            ))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if rects.count != days.count { rebuildRects() }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let grid = dark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.07)
        grid.setStroke()
        let plotBottom = bounds.height - 26
        for step in 0...4 {
            let y = 5 + (plotBottom - 5) * CGFloat(step) / 4
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 0, y: y))
            line.line(to: NSPoint(x: bounds.width, y: y))
            line.lineWidth = 0.5
            line.stroke()
        }

        guard !days.isEmpty else {
            let text = NSLocalizedString("activity.chart.empty", comment: "")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
            return
        }

        let calendar = Calendar.current
        for (index, rect) in rects.enumerated() {
            let day = days[index]
            if index == selectedIndex {
                NSColor.controlAccentColor.withAlphaComponent(0.045).setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.midX - bounds.width / CGFloat(days.count) / 2,
                                                y: 0,
                                                width: bounds.width / CGFloat(days.count),
                                                height: bounds.height), xRadius: 5, yRadius: 5).fill()
            }
            let keyHeight = day.total > 0 ? rect.height * CGFloat(day.keyPresses) / CGFloat(day.total) : 0
            let clickHeight = rect.height - keyHeight
            let keyRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: keyHeight)
            let clickRect = NSRect(x: rect.minX, y: rect.maxY - clickHeight, width: rect.width, height: clickHeight)
            let radius = min(4, rect.width / 3)
            NSGraphicsContext.current?.saveGraphicsState()
            let fullBar = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            fullBar.addClip()
            if day.total == 0 {
                NSColor.separatorColor.setFill()
                fullBar.fill()
            }
            if keyHeight > 0 {
                NSColor(calibratedRed: 0.34, green: 0.65, blue: 0.94, alpha: 1).setFill()
                NSBezierPath(rect: keyRect).fill()
            }
            if day.total > 0, clickHeight > 0 {
                NSColor(calibratedRed: 0.94, green: 0.72, blue: 0.38, alpha: 1).setFill()
                NSBezierPath(rect: clickRect).fill()
            }
            NSGraphicsContext.current?.restoreGraphicsState()
            if index == hoveredIndex || index == selectedIndex {
                NSColor.controlAccentColor.withAlphaComponent(index == selectedIndex ? 0.72 : 0.36).setStroke()
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 4, yRadius: 4)
                outline.lineWidth = index == selectedIndex ? 1.5 : 1
                outline.stroke()
            }
            if shouldShowLabel(at: index) {
                let label = dayLabel(for: day.date, calendar: calendar)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: index == selectedIndex ? .medium : .regular),
                    .foregroundColor: index == selectedIndex ? NSColor.labelColor : NSColor.secondaryLabelColor
                ]
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: min(bounds.width - size.width, max(0, rect.midX - size.width / 2)), y: bounds.height - 16), withAttributes: attributes)
            }
        }
    }

    private func shouldShowLabel(at index: Int) -> Bool {
        if days.count <= 10 { return true }
        return index % 5 == 0 || index == selectedIndex || index == days.count - 1
    }

    private func dayLabel(for date: Date, calendar: Calendar) -> String {
        if days.count <= 2 { return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .none) }
        if days.count <= 10 {
            let symbols = DateFormatter().veryShortWeekdaySymbols ?? []
            let index = calendar.component(.weekday, from: date) - 1
            return symbols.indices.contains(index) ? symbols[index] : ""
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }

    private func hitIndex(at point: NSPoint) -> Int? {
        guard !days.isEmpty else { return nil }
        let index = Int(point.x / bounds.width * CGFloat(days.count))
        return days.indices.contains(index) ? index : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = hitIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        selectDay(at: index)
        if event.clickCount == 2 { onOpenDay?(index) }
    }

    override func keyDown(with event: NSEvent) {
        guard !days.isEmpty else { return super.keyDown(with: event) }
        let current = selectedIndex ?? days.count - 1
        switch event.keyCode {
        case 123: selectDay(at: max(0, current - 1))
        case 124: selectDay(at: min(days.count - 1, current + 1))
        case 115: selectDay(at: 0)
        case 119: selectDay(at: days.count - 1)
        case 36, 76:
            if let selectedIndex { onOpenDay?(selectedIndex) }
        case 48:
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
        case 53:
            selectedIndex = nil
            updateAccessibility()
            needsDisplay = true
            onSelectionCleared?()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let selectedIndex, days.indices.contains(selectedIndex), let onOpenDay else { return false }
        onOpenDay(selectedIndex)
        return true
    }

    override func resignFirstResponder() -> Bool {
        hoveredIndex = nil
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(trackingArea!)
    }

    override func mouseMoved(with event: NSEvent) {
        let index = hitIndex(at: convert(event.locationInWindow, from: nil))
        guard hoveredIndex != index else { return }
        hoveredIndex = index
        toolTip = index.flatMap { tooltip(for: $0) }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        toolTip = nil
        needsDisplay = true
    }

    private func tooltip(for index: Int) -> String {
        let day = days[index]
        return DateFormatter.localizedString(from: day.date, dateStyle: .medium, timeStyle: .none)
            + "\n" + String(format: NSLocalizedString("heatmap.detailFormat", comment: ""), day.keyPresses, day.clicks)
    }

    private func updateAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(NSLocalizedString("activity.chart.label", comment: ""))
        setAccessibilityHelp(NSLocalizedString("activity.chart.hint", comment: ""))
        if let selectedIndex, days.indices.contains(selectedIndex) {
            setAccessibilityValue(tooltip(for: selectedIndex))
        } else {
            setAccessibilityValue(NSLocalizedString("heatmap.noSelection", comment: ""))
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        guard let window else { return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willMiniaturizeNotification, NSWindow.willCloseNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.hoveredIndex = nil
                self?.toolTip = nil
                self?.needsDisplay = true
            })
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    deinit { windowObservers.forEach(NotificationCenter.default.removeObserver) }
}

final class ActivityKeycapView: NSView {
    private let keyName: String
    private var keyLabel: NSTextField?

    init(name: String, count: Int) {
        keyName = name
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 0.5
        let label = NSTextField(labelWithAttributedString: KeyCountRowView.attributedKeyLabel(for: name, font: .systemFont(ofSize: 11, weight: .medium), compact: true))
        label.alignment = .center
        keyLabel = label
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        let countLabel = NSTextField(labelWithString: NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal))
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .left
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [label, countLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 25),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        toolTip = name
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(name)
        setAccessibilityValue(countLabel.stringValue)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = NSColor.clear.cgColor
        layer?.shadowOpacity = 0
        keyLabel?.attributedStringValue = KeyCountRowView.attributedKeyLabel(
            for: keyName, font: .systemFont(ofSize: 11, weight: .medium),
            appearance: effectiveAppearance, compact: true)
    }
}

final class ActivityDisclosureButton: NSButton {
    private let chevron = NSImageView()

    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        font = .systemFont(ofSize: 12)
        contentTintColor = .secondaryLabelColor
        image = nil
        setButtonType(.momentaryChange)
        image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        imagePosition = .imageLeading
        imageHugsTitle = true
        attributedTitle = NSAttributedString(string: "  " + title, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        alignment = .left
        chevron.contentTintColor = .secondaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        NSLayoutConstraint.activate([
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
            heightAnchor.constraint(equalToConstant: 24)
        ])
        setExpanded(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setExpanded(_ expanded: Bool) {
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
    }

}

final class ActivityMonthCalendarView: NSView {
    var metric: ActivityHeatmapView.Metric = .combined {
        didSet { needsDisplay = true }
    }
    var onSelectionChanged: ((ActivityHeatmapView.DayActivity?) -> Void)?
    var onOpenDay: ((Date) -> Void)?

    private var days: [ActivityHeatmapView.DayActivity] = []
    private var month = Date()
    private var selectedDate: Date?
    private var hoveredIndex: Int?
    private var dayRects: [NSRect] = []
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 600, height: 315) }
    override var acceptsFirstResponder: Bool { !days.isEmpty }

    override func keyDown(with event: NSEvent) {
        let calendar = Calendar.current
        let offset: Int
        switch event.keyCode {
        case 123: offset = -1
        case 124: offset = 1
        case 125: offset = 7
        case 126: offset = -7
        case 36, 76:
            if let selectedDate { onOpenDay?(selectedDate) }
            return
        case 48:
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return
        default: return super.keyDown(with: event)
        }
        guard let date = calendar.date(byAdding: .day, value: offset, to: selectedDate ?? month),
              let day = days.first(where: { calendar.isDate($0.date, inSameDayAs: date) }) else { return }
        update(days: days, selectedDate: date)
        onSelectionChanged?(day)
    }

    func update(days: [ActivityHeatmapView.DayActivity], selectedDate: Date?) {
        self.days = days.sorted { $0.date < $1.date }
        self.selectedDate = selectedDate
        if let selectedDate { month = selectedDate }
        rebuildRects()
        needsLayout = true
        needsDisplay = true
        updateAccessibility()
    }

    override func layout() {
        super.layout()
        rebuildRects()
    }

    private func displayedDays() -> [ActivityHeatmapView.DayActivity?] {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: month)
        guard let first = calendar.date(from: components),
              let dayRange = calendar.range(of: .day, in: .month, for: first) else { return [] }
        let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        return (0..<leading).map { _ in nil } + dayRange.map { dayNumber in
            let date = calendar.date(byAdding: .day, value: dayNumber - 1, to: first)!
            return days.first { calendar.isDate($0.date, inSameDayAs: date) }
                ?? ActivityHeatmapView.DayActivity(date: date, keyPresses: 0, clicks: 0)
        }
    }

    private func rebuildRects() {
        let items = displayedDays()
        let columns = 7
        let spacing: CGFloat = 6
        let width = (bounds.width - spacing * 6) / 7
        dayRects = items.indices.map { index in
            NSRect(x: CGFloat(index % columns) * (width + spacing),
                   y: 75 + CGFloat(index / columns) * 43,
                   width: width, height: 35)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if dayRects.count != displayedDays().count { rebuildRects() }
        let calendar = Calendar.current
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = Locale.current.identifier.hasPrefix("zh") ? "yyyy 年 M 月" : "MMMM yyyy"
        drawText(monthFormatter.string(from: month), at: NSPoint(x: 0, y: 0), size: 12, color: .labelColor)
        let explanation = NSLocalizedString("activity.calendarIntensity", comment: "")
        let explanationWidth = explanation.size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width
        drawText(explanation, at: NSPoint(x: max(0, bounds.width - explanationWidth), y: 3), size: 10, color: .secondaryLabelColor)
        let weekdays = DateFormatter().veryShortWeekdaySymbols ?? []
        for column in 0..<7 {
            let index = (column + calendar.firstWeekday - 1) % 7
            let text = weekdays.indices.contains(index) ? weekdays[index] : ""
            let textWidth = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width
            drawText(text, at: NSPoint(x: CGFloat(column) * (bounds.width / 7) + (bounds.width / 7 - textWidth) / 2, y: 43),
                     size: 10, color: .secondaryLabelColor)
        }
        let items = displayedDays()
        let nonzero = items.compactMap { $0 }.map { metric.value(for: $0) }.filter { $0 > 0 }.sorted()
        let maximum = max(1, nonzero.last ?? 1)
        for (index, rect) in dayRects.enumerated() where index < items.count {
            guard let day = items[index] else { continue }
            let value = metric.value(for: day)
            let intensity = value == 0 ? 0.025 : 0.13 + 0.24 * CGFloat(value) / CGFloat(maximum)
            let selected = selectedDate.map { calendar.isDate($0, inSameDayAs: day.date) } ?? false
            let hovered = hoveredIndex == index
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let emptyColor = dark ? NSColor.white.withAlphaComponent(0.035) : NSColor.black.withAlphaComponent(0.035)
            (value > 0 ? NSColor.systemBlue.withAlphaComponent(intensity) : emptyColor).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            if selected || hovered {
                NSColor.controlAccentColor.withAlphaComponent(selected ? 0.9 : 0.45).setStroke()
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 6, yRadius: 6)
                outline.lineWidth = selected ? 1.5 : 1
                outline.stroke()
            }
            let text = "\(calendar.component(.day, from: day.date))"
            let color: NSColor = value > 0 ? .labelColor : .tertiaryLabelColor
            let size = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)])
            drawText(text, at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), size: 10, color: color)
        }
    }

    private func drawText(_ text: String, at point: NSPoint, size: CGFloat, color: NSColor) {
        text.draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(trackingArea!)
    }

    private func index(at point: NSPoint) -> Int? { dayRects.firstIndex { $0.contains(point) } }

    override func mouseMoved(with event: NSEvent) {
        let next = index(at: convert(event.locationInWindow, from: nil))
        guard next != hoveredIndex else { return }
        hoveredIndex = next
        toolTip = next.flatMap { index in
            guard let day = displayedDays()[index] else { return nil }
            return String(format: NSLocalizedString("heatmap.detailFormat", comment: ""), day.keyPresses, day.clicks)
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        toolTip = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)),
              let day = displayedDays()[index] else { return }
        guard day.date <= Calendar.current.startOfDay(for: Date()) else { return }
        window?.makeFirstResponder(self)
        selectedDate = day.date
        onSelectionChanged?(day)
        if event.clickCount == 2 { onOpenDay?(day.date) }
        updateAccessibility()
        needsDisplay = true
    }

    private func updateAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(NSLocalizedString("allTimeStats.heatmap", comment: ""))
        setAccessibilityHelp(NSLocalizedString("activity.chart.hint", comment: ""))
        if let selectedDate {
            let day = days.first { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }
            setAccessibilityValue(DateFormatter.localizedString(from: selectedDate, dateStyle: .medium, timeStyle: .none)
                + ", " + String(format: NSLocalizedString("heatmap.detailFormat", comment: ""), day?.keyPresses ?? 0, day?.clicks ?? 0))
        }
    }
}

