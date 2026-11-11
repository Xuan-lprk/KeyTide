import AppKit

final class AllTimeStatsViewController: NSViewController {
    private enum Range: Int {
        case today = 0, week = 1, month = 2

        var historyRange: StatsManager.HistoryRange {
            switch self {
            case .today: return .today
            case .week: return .week
            case .month: return .month
            }
        }

        var dayCount: Int {
            switch self {
            case .today: return 1
            case .week: return 7
            case .month: return 30
            }
        }
    }

    private var scrollView: NSScrollView!
    private var contentStack: NSStackView!
    private var rangeControl: NSSegmentedControl!
    private var dateRangeLabel: NSTextField!
    private var previousButton: NSButton!
    private var nextButton: NSButton!
    private var totalLabel: NSTextField!
    private var keyTotalLabel: NSTextField!
    private var clickTotalLabel: NSTextField!
    private var overviewView: ActivityOverviewView!
    private var selectedDayLabel: NSTextField!
    private var selectedDayDetailLabel: NSTextField!
    private var openSelectedDayButton: NSButton!
    private var topKeysStack: NSStackView!
    private var calendarButton: ActivityDisclosureButton!
    private var calendarContainer: NSView!
    private var calendarContent: NSStackView!
    private var heatmapMetricControl: NSSegmentedControl!
    private var heatmapIntensityLabel: NSTextField!
    private var heatmapView: ActivityHeatmapView!
    private var monthCalendarView: ActivityMonthCalendarView!
    private var insightsContainer: NSView!
    private var insightsContent: NSStackView!
    private var insightsGrid: NSStackView!
    private var lifetimeLabel: NSTextField!

    private var range: Range = .week
    private var periodOffset = 0
    private var selectedDate: Date?
    private var visibleDays: [ActivityHeatmapView.DayActivity] = []
    private var loadedDays: [Date: ActivityHeatmapView.DayActivity] = [:]
    private var didSetInitialSelection = false

    override func loadView() {
        let content = AppearanceTrackingView(frame: NSRect(x: 0, y: 0, width: 900, height: 740))
        content.wantsLayer = true
        content.onEffectiveAppearanceChange = { [weak self] in self?.updateAppearance() }
        view = content
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        refreshData()
        updateAppearance()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        scrollToTop()
        view.window?.acceptsMouseMovedEvents = true
    }

    private func setupUI() {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        contentStack.edgeInsets = NSEdgeInsets(top: 27, left: 32, bottom: 22, right: 32)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])

        setupHeader()
        setupOverview()
        setupDayDetails()
        setupTopKeys()
        setupCalendar()
        setupInsights()

        let privacyLabel = StatsWindowStyle.secondaryLabel(NSLocalizedString("activity.privacy", comment: ""))
        privacyLabel.font = .systemFont(ofSize: 10)
        privacyLabel.alignment = .center
        contentStack.setCustomSpacing(18, after: insightsContainer)
        StatsWindowStyle.fullWidth(privacyLabel, in: contentStack)
    }

    private func setupHeader() {
        let titleLabel = StatsWindowStyle.title("allTimeStats.title")
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        rangeControl = NSSegmentedControl(
            labels: ["appStats.range.today", "activity.range.week", "activity.range.month"].map { NSLocalizedString($0, comment: "") },
            trackingMode: .selectOne,
            target: self,
            action: #selector(rangeChanged)
        )
        rangeControl.selectedSegment = range.rawValue
        rangeControl.controlSize = .regular
        rangeControl.setAccessibilityLabel(NSLocalizedString("activity.range.label", comment: ""))
        let header = NSView()
        for item in [titleLabel, rangeControl] as [NSView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(item)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: rangeControl.leadingAnchor, constant: -14),
            rangeControl.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            rangeControl.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(equalToConstant: 32)
        ])
        StatsWindowStyle.fullWidth(header, in: contentStack)

        previousButton = symbolButton("chevron.left", action: #selector(previousPeriod), label: NSLocalizedString("activity.previousPeriod", comment: ""))
        nextButton = symbolButton("chevron.right", action: #selector(nextPeriod), label: NSLocalizedString("activity.nextPeriod", comment: ""))
        dateRangeLabel = StatsWindowStyle.secondaryLabel()
        dateRangeLabel.alignment = .center
        dateRangeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let dateNavigation = NSView()
        for item in [previousButton, dateRangeLabel, nextButton] as [NSView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            dateNavigation.addSubview(item)
        }
        NSLayoutConstraint.activate([
            previousButton.trailingAnchor.constraint(equalTo: dateRangeLabel.leadingAnchor, constant: -34),
            previousButton.centerYAnchor.constraint(equalTo: dateNavigation.centerYAnchor),
            dateRangeLabel.centerXAnchor.constraint(equalTo: dateNavigation.centerXAnchor),
            dateRangeLabel.centerYAnchor.constraint(equalTo: dateNavigation.centerYAnchor),
            nextButton.leadingAnchor.constraint(equalTo: dateRangeLabel.trailingAnchor, constant: 34),
            nextButton.centerYAnchor.constraint(equalTo: dateNavigation.centerYAnchor),
            dateNavigation.heightAnchor.constraint(equalToConstant: 26)
        ])
        contentStack.setCustomSpacing(28, after: header)
        StatsWindowStyle.fullWidth(dateNavigation, in: contentStack)
    }

    private func setupOverview() {
        totalLabel = NSTextField(labelWithString: "0")
        totalLabel.font = .monospacedDigitSystemFont(ofSize: 37, weight: .medium)
        totalLabel.textColor = .labelColor
        let unitLabel = StatsWindowStyle.secondaryLabel(NSLocalizedString("activity.totalInteractions", comment: ""))
        let totalRow = NSStackView(views: [totalLabel, unitLabel])
        totalRow.orientation = .horizontal
        totalRow.alignment = .lastBaseline
        totalRow.spacing = 9
        contentStack.setCustomSpacing(26, after: contentStack.arrangedSubviews.last!)
        StatsWindowStyle.fullWidth(totalRow, in: contentStack)

        keyTotalLabel = legendLabel(color: .systemBlue)
        clickTotalLabel = legendLabel(color: .systemOrange)
        let legend = NSStackView(views: [keyTotalLabel, clickTotalLabel])
        legend.orientation = .horizontal
        legend.spacing = 18
        legend.edgeInsets = NSEdgeInsets(top: 0, left: 13, bottom: 0, right: 0)
        contentStack.setCustomSpacing(8, after: totalRow)
        StatsWindowStyle.fullWidth(legend, in: contentStack)
        let keySwatch = NSView()
        keySwatch.wantsLayer = true
        keySwatch.layer?.backgroundColor = NSColor.systemBlue.cgColor
        keySwatch.layer?.cornerRadius = 1.5
        let clickSwatch = NSView()
        clickSwatch.wantsLayer = true
        clickSwatch.layer?.backgroundColor = NSColor.systemOrange.cgColor
        clickSwatch.layer?.cornerRadius = 1.5
        legend.addSubview(keySwatch)
        legend.addSubview(clickSwatch)
        for swatch in [keySwatch, clickSwatch] {
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.widthAnchor.constraint(equalToConstant: 7).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 7).isActive = true
        }
        keySwatch.centerYAnchor.constraint(equalTo: keyTotalLabel.centerYAnchor).isActive = true
        clickSwatch.centerYAnchor.constraint(equalTo: clickTotalLabel.centerYAnchor).isActive = true
        keyTotalLabel.leadingAnchor.constraint(equalTo: keySwatch.trailingAnchor, constant: 6).isActive = true
        clickTotalLabel.leadingAnchor.constraint(equalTo: clickSwatch.trailingAnchor, constant: 6).isActive = true

        overviewView = ActivityOverviewView()
        overviewView.onSelectionChanged = { [weak self] index in self?.selectVisibleDay(at: index) }
        overviewView.onSelectionCleared = { [weak self] in
            self?.selectedDate = nil
            self?.updateSelectedDay()
        }
        overviewView.onOpenDay = { [weak self] index in
            guard let self, self.visibleDays.indices.contains(index) else { return }
            self.selectVisibleDay(at: index)
            self.openSelectedDay()
        }
        overviewView.translatesAutoresizingMaskIntoConstraints = false
        overviewView.heightAnchor.constraint(equalToConstant: 218).isActive = true
        contentStack.setCustomSpacing(18, after: legend)
        StatsWindowStyle.fullWidth(overviewView, in: contentStack)
    }

    private func setupDayDetails() {
        selectedDayLabel = NSTextField(labelWithString: "")
        selectedDayLabel.font = .systemFont(ofSize: 12, weight: .medium)
        selectedDayDetailLabel = StatsWindowStyle.secondaryLabel()
        selectedDayDetailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let textStack = NSStackView(views: [selectedDayLabel, selectedDayDetailLabel])
        textStack.orientation = .horizontal
        textStack.alignment = .centerY
        textStack.spacing = 18

        openSelectedDayButton = NSButton(title: NSLocalizedString("heatmap.openGrowth", comment: "") + " ↗", target: self, action: #selector(openSelectedDay))
        openSelectedDayButton.isBordered = false
        openSelectedDayButton.font = .systemFont(ofSize: 11)
        openSelectedDayButton.contentTintColor = .controlAccentColor
        openSelectedDayButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [textStack, NSView(), openSelectedDayButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.heightAnchor.constraint(equalToConstant: 32).isActive = true
        contentStack.setCustomSpacing(12, after: overviewView)
        StatsWindowStyle.fullWidth(row, in: contentStack)
        contentStack.setCustomSpacing(22, after: row)
        StatsWindowStyle.fullWidth(StatsWindowStyle.separator(), in: contentStack)
    }

    private func setupTopKeys() {
        let titleLabel = StatsWindowStyle.secondaryLabel(NSLocalizedString("allTimeStats.topKeys", comment: ""))
        topKeysStack = NSStackView()
        topKeysStack.orientation = .horizontal
        topKeysStack.alignment = .centerY
        topKeysStack.distribution = .fillEqually
        topKeysStack.spacing = 18
        let row = NSStackView(views: [titleLabel, topKeysStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 26
        contentStack.setCustomSpacing(20, after: contentStack.arrangedSubviews.last!)
        StatsWindowStyle.fullWidth(row, in: contentStack)
        contentStack.setCustomSpacing(22, after: row)
        StatsWindowStyle.fullWidth(StatsWindowStyle.separator(), in: contentStack)
    }

    private func setupCalendar() {
        calendarButton = ActivityDisclosureButton(title: NSLocalizedString("allTimeStats.heatmap", comment: ""), target: self, action: #selector(toggleCalendar))
        calendarButton.setExpanded(true)
        contentStack.setCustomSpacing(14, after: contentStack.arrangedSubviews.last!)
        StatsWindowStyle.fullWidth(calendarButton, in: contentStack)

        calendarContent = NSStackView()
        calendarContent.orientation = .vertical
        calendarContent.alignment = .leading
        calendarContent.spacing = 11
        calendarContent.edgeInsets = NSEdgeInsets(top: 13, left: 0, bottom: 0, right: 0)
        calendarContent.isHidden = false

        heatmapMetricControl = NSSegmentedControl(labels: ActivityHeatmapView.Metric.allCases.map(\.title), trackingMode: .selectOne, target: self, action: #selector(heatmapMetricChanged))
        heatmapMetricControl.selectedSegment = 0
        heatmapMetricControl.controlSize = .small
        heatmapMetricControl.setAccessibilityLabel(NSLocalizedString("heatmap.metricLabel", comment: ""))
        let header = NSStackView(views: [NSView(), heatmapMetricControl])
        header.orientation = .horizontal
        header.distribution = .gravityAreas
        header.isHidden = true
        StatsWindowStyle.fullWidth(header, in: calendarContent)
        heatmapIntensityLabel = StatsWindowStyle.secondaryLabel(wrapping: true)
        heatmapIntensityLabel.font = .systemFont(ofSize: 10)
        StatsWindowStyle.fullWidth(heatmapIntensityLabel, in: calendarContent)

        heatmapView = ActivityHeatmapView()
        heatmapView.onOpenDay = { date in KeyboardHeatmapWindowController.shared.show(day: date) }
        heatmapView.onSelectionChanged = { [weak self] day in self?.calendarSelectionChanged(day) }
        monthCalendarView = ActivityMonthCalendarView()
        monthCalendarView.onOpenDay = { date in KeyboardHeatmapWindowController.shared.show(day: date) }
        monthCalendarView.onSelectionChanged = { [weak self] day in self?.calendarSelectionChanged(day) }
        StatsWindowStyle.fullWidth(monthCalendarView, in: calendarContent)
        calendarContainer = wrappingContainer(for: calendarContent)
        calendarContainer.isHidden = false
        StatsWindowStyle.fullWidth(calendarContainer, in: contentStack)
    }

    private func setupInsights() {
        let heading = NSTextField(labelWithString: NSLocalizedString("activity.moreInsights", comment: ""))
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        contentStack.setCustomSpacing(17, after: calendarContainer)
        StatsWindowStyle.fullWidth(heading, in: contentStack)

        insightsContent = NSStackView()
        insightsContent.orientation = .vertical
        insightsContent.alignment = .leading
        insightsContent.spacing = 13
        insightsContent.edgeInsets = NSEdgeInsets(top: 15, left: 0, bottom: 0, right: 0)
        lifetimeLabel = StatsWindowStyle.secondaryLabel(wrapping: true)
        StatsWindowStyle.fullWidth(lifetimeLabel, in: insightsContent)
        insightsGrid = NSStackView()
        insightsGrid.orientation = .vertical
        insightsGrid.spacing = 13
        StatsWindowStyle.fullWidth(insightsGrid, in: insightsContent)
        insightsContainer = wrappingContainer(for: insightsContent)
        StatsWindowStyle.fullWidth(insightsContainer, in: contentStack)
    }

    func refreshData() {
        let manager = StatsManager.shared
        let stats = manager.getAllTimeStats()
        let keys = manager.historySeries(range: range.historyRange, metric: .keyPresses)
        let calendar = Calendar.current
        loadedDays = Dictionary(uniqueKeysWithValues: manager.localHistorySnapshot().values.map { daily in
            let date = calendar.startOfDay(for: daily.date)
            return (date, ActivityHeatmapView.DayActivity(date: date, keyPresses: max(0, daily.keyPresses), clicks: max(0, daily.totalClicks)))
        })
        visibleDays = keys.map { point in
            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -periodOffset * range.dayCount, to: point.date) ?? point.date)
            return loadedDays[day] ?? ActivityHeatmapView.DayActivity(date: day, keyPresses: 0, clicks: 0)
        }
        if !didSetInitialSelection {
            selectedDate = visibleDays.last?.date
            didSetInitialSelection = true
        }
        updateOverview()
        updateHeatmapMetricDescription()
        heatmapView.activityData = manager.heatmapActivityData().map {
            ActivityHeatmapView.DayActivity(date: $0.date, keyPresses: $0.keyPresses, clicks: $0.clicks)
        }
        monthCalendarView.update(days: heatmapView.activityData, selectedDate: selectedDate)
        updateLifetime(stats)
        updateInsights(stats)
        updateTopKeys(stats.keyPressCounts)
    }

    private func updateOverview() {
        let keyTotal = visibleDays.reduce(0) { $0 + $1.keyPresses }
        let clickTotal = visibleDays.reduce(0) { $0 + $1.clicks }
        totalLabel.stringValue = formatNumber(keyTotal + clickTotal)
        keyTotalLabel.stringValue = String(format: NSLocalizedString("activity.keysFormat", comment: ""), formatNumber(keyTotal))
        clickTotalLabel.stringValue = String(format: NSLocalizedString("activity.clicksFormat", comment: ""), formatNumber(clickTotal))
        overviewView.update(days: visibleDays, selectedDate: selectedDate)
        monthCalendarView.update(days: heatmapView.activityData, selectedDate: selectedDate)
        nextButton.isEnabled = periodOffset > 0
        previousButton.isEnabled = visibleDays.first.map { first in
            loadedDays.keys.contains { $0 < first.date }
        } ?? false
        if let first = visibleDays.first?.date, let last = visibleDays.last?.date {
            if range == .today {
                dateRangeLabel.stringValue = DateFormatter.localizedString(from: first, dateStyle: .medium, timeStyle: .none)
            } else {
                dateRangeLabel.stringValue = String(format: NSLocalizedString("activity.periodFormat", comment: ""),
                    DateFormatter.localizedString(from: first, dateStyle: .medium, timeStyle: .none),
                    DateFormatter.localizedString(from: last, dateStyle: .medium, timeStyle: .none))
            }
        } else {
            dateRangeLabel.stringValue = NSLocalizedString("allTimeStats.noData", comment: "")
        }
        updateSelectedDay()
    }

    private func updateSelectedDay() {
        let selected = selectedDate.map { date in
            let day = Calendar.current.startOfDay(for: date)
            return loadedDays[day] ?? ActivityHeatmapView.DayActivity(date: day, keyPresses: 0, clicks: 0)
        }
        guard let selected else {
            selectedDayLabel.stringValue = NSLocalizedString("heatmap.noSelection", comment: "")
            selectedDayDetailLabel.stringValue = NSLocalizedString("activity.selectDay", comment: "")
            openSelectedDayButton.isEnabled = false
            return
        }
        selectedDayLabel.stringValue = DateFormatter.localizedString(from: selected.date, dateStyle: .full, timeStyle: .none)
        selectedDayDetailLabel.stringValue = String(format: NSLocalizedString("heatmap.detailFormat", comment: ""), selected.keyPresses, selected.clicks)
        openSelectedDayButton.isEnabled = true
        openSelectedDayButton.setAccessibilityLabel(String(format: NSLocalizedString("activity.openGrowthFor", comment: ""), selectedDayLabel.stringValue))
    }

    private func selectVisibleDay(at index: Int) {
        guard visibleDays.indices.contains(index) else { return }
        selectedDate = visibleDays[index].date
        if let heatmapIndex = heatmapView.activityData.firstIndex(where: { Calendar.current.isDate($0.date, inSameDayAs: visibleDays[index].date) }) {
            heatmapView.selectDay(at: heatmapIndex)
        }
        overviewView.update(days: visibleDays, selectedDate: selectedDate)
        updateSelectedDay()
    }

    private func calendarSelectionChanged(_ day: ActivityHeatmapView.DayActivity?) {
        selectedDate = day?.date
        monthCalendarView.update(days: heatmapView.activityData, selectedDate: selectedDate)
        if let day, !visibleDays.contains(where: { Calendar.current.isDate($0.date, inSameDayAs: day.date) }) {
            overviewView.update(days: visibleDays, selectedDate: nil)
            updateSelectedDay()
            return
        }
        overviewView.update(days: visibleDays, selectedDate: selectedDate)
        updateSelectedDay()
    }

    private func updateLifetime(_ stats: AllTimeStats) {
        if let first = stats.firstDate, let last = stats.lastDate {
            let start = DateFormatter.localizedString(from: first, dateStyle: .medium, timeStyle: .none)
            let end = DateFormatter.localizedString(from: last, dateStyle: .medium, timeStyle: .none)
            let days = (Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0) + 1
            lifetimeLabel.stringValue = String(format: NSLocalizedString("activity.lifetimeFormat", comment: ""),
                formatNumber(stats.totalKeyPresses), formatNumber(stats.totalClicks), stats.formattedMouseDistance, stats.formattedScrollDistance,
                NSLocalizedString("allTimeStats.cumulative", comment: "") + " · " + String(format: NSLocalizedString("allTimeStats.rangeFormat", comment: ""), start, end, days))
        } else {
            lifetimeLabel.stringValue = NSLocalizedString("allTimeStats.cumulativeEmpty", comment: "")
        }
    }

    private func updateInsights(_ stats: AllTimeStats) {
        clear(insightsGrid)
        guard stats.activeDays > 0 else {
            insightsGrid.addArrangedSubview(StatsWindowStyle.secondaryLabel(NSLocalizedString("allTimeStats.noData", comment: "")))
            return
        }
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        let averageKeys = stats.keyActiveDays > 0 ? Int((Double(stats.totalKeyPresses) / Double(stats.keyActiveDays)).rounded()) : 0
        let averageClicks = stats.clickActiveDays > 0 ? Int((Double(stats.totalClicks) / Double(stats.clickActiveDays)).rounded()) : 0
        insightsGrid.addArrangedSubview(insightRow([
            ActivityInsightView(title: NSLocalizedString("activity.insight.keyboardPeak", comment: ""), value: formatNumber(stats.maxDailyKeyPresses), detail: stats.maxDailyKeyPressesDate.map { dateFormatter.string(from: $0) } ?? "—") { [weak self] in self?.showPeakDay(stats.maxDailyKeyPressesDate) },
            ActivityInsightView(title: NSLocalizedString("activity.insight.mousePeak", comment: ""), value: formatNumber(stats.maxDailyClicks), detail: stats.maxDailyClicksDate.map { dateFormatter.string(from: $0) } ?? "—") { [weak self] in self?.showPeakDay(stats.maxDailyClicksDate) },
            ActivityInsightView(title: NSLocalizedString("allTimeStats.avgKeyPressesPerDay", comment: ""), value: formatNumber(averageKeys), detail: NSLocalizedString("insights.activeDayAverage", comment: "")),
            ActivityInsightView(title: NSLocalizedString("allTimeStats.avgClicksPerDay", comment: ""), value: formatNumber(averageClicks), detail: NSLocalizedString("insights.activeDayAverage", comment: ""))
        ]))
        var weekday = "—"
        if let index = stats.mostActiveWeekday, index > 0, index <= (dateFormatter.shortWeekdaySymbols?.count ?? 0) {
            weekday = dateFormatter.shortWeekdaySymbols?[index - 1] ?? "—"
        }
        let clickTotal = max(1, stats.totalLeftClicks + stats.totalNonLeftClicks)
        let leftRatio = Int((Double(stats.totalLeftClicks) / Double(clickTotal) * 100).rounded())
        let ratio = stats.inputRatio
        let styleKey = ratio > 5 ? "insights.style.keyboard" : ratio < 1 ? "insights.style.mouse" : "insights.style.balanced"
        insightsGrid.addArrangedSubview(insightRow([
            ActivityInsightView(title: NSLocalizedString("allTimeStats.mostActiveWeekday", comment: ""), value: weekday, detail: NSLocalizedString("insights.subtitle.weeklyBest", comment: "")),
            ActivityInsightView(title: NSLocalizedString("insights.clickRatio", comment: ""), value: "\(leftRatio)% / \(100 - leftRatio)%", detail: NSLocalizedString("insights.leftRight", comment: "")),
            ActivityInsightView(title: NSLocalizedString("insights.perfectionist", comment: ""), value: String(format: "%.1f%%", stats.correctionRate * 100), detail: NSLocalizedString("activity.insight.revision", comment: "")),
            ActivityInsightView(title: NSLocalizedString("insights.inputStyle", comment: ""), value: NSLocalizedString(styleKey, comment: ""), detail: String(format: NSLocalizedString("insights.subtitle.ratioFormat", comment: ""), ratio))
        ]))
        let metersPerPixel = StatsManager.shared.mouseDistanceMetersPerPixel
        let marathon = stats.totalMouseDistance * metersPerPixel / 42195
        let everest = stats.totalScrollDistance * metersPerPixel / 8848
        let funLabel = StatsWindowStyle.secondaryLabel(wrapping: true)
        funLabel.stringValue = "↗ " + String(format: NSLocalizedString("allTimeStats.distanceFootnote", comment: ""), marathon, everest)
        insightsGrid.addArrangedSubview(funLabel)
        let story = StatsWindowStyle.secondaryLabel(wrapping: true)
        story.stringValue = String(format: NSLocalizedString("activity.insight.recordedDays", comment: ""), stats.activeDays)
        insightsGrid.addArrangedSubview(story)
        for row in insightsGrid.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: insightsGrid.widthAnchor).isActive = true
        }
    }

    private func insightRow(_ views: [ActivityInsightView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 14
        return row
    }

    private func wrappingContainer(for content: NSView) -> NSView {
        let container = NSView()
        container.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func updateTopKeys(_ counts: [String: Int]) {
        clear(topKeysStack)
        let sorted = keyBreakdownDisplayCounts(from: counts).sorted {
            $0.value == $1.value ? $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending : $0.value > $1.value
        }.prefix(5)
        guard !sorted.isEmpty else {
            topKeysStack.addArrangedSubview(StatsWindowStyle.secondaryLabel(NSLocalizedString("keyBreakdown.empty", comment: "")))
            return
        }
        for item in sorted { topKeysStack.addArrangedSubview(ActivityKeycapView(name: item.key, count: item.value)) }
    }

    private func updateHeatmapMetricDescription() {
        monthCalendarView.metric = heatmapView.metric
        heatmapIntensityLabel.isHidden = true
    }

    private func showPeakDay(_ date: Date?) {
        guard let date else { return }
        guard let index = heatmapView.activityData.firstIndex(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }) else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = NSLocalizedString("heatmap.outsideCalendar", comment: "")
            alert.informativeText = NSLocalizedString("heatmap.outsideCalendarDetail", comment: "")
            alert.addButton(withTitle: NSLocalizedString("heatmap.openGrowth", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("settings.cancel", comment: ""))
            if let window = view.window {
                alert.beginSheetModal(for: window) { response in
                    if response == .alertFirstButtonReturn { KeyboardHeatmapWindowController.shared.show(day: date) }
                }
            }
            return
        }
        setCalendarExpanded(true)
        heatmapView.selectDay(at: index)
        monthCalendarView.update(days: heatmapView.activityData, selectedDate: heatmapView.activityData[index].date)
        view.layoutSubtreeIfNeeded()
        let target = NSPoint(x: 0, y: max(0, calendarButton.frame.minY - 15))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            scrollView.contentView.animator().setBoundsOrigin(target)
        }
        view.window?.makeFirstResponder(monthCalendarView)
    }

    private func setCalendarExpanded(_ expanded: Bool) {
        calendarContent.isHidden = !expanded
        calendarButton.setExpanded(expanded)
        calendarButton.setAccessibilityExpanded(expanded)
        calendarContainer.isHidden = !expanded
        contentStack.setCustomSpacing(expanded ? 17 : 0, after: calendarContainer)
    }

    private func symbolButton(_ symbol: String, action: Selector, label: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(label)
        return button
    }

    private func legendLabel(color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func clear(_ stack: NSStackView) {
        for child in stack.arrangedSubviews {
            stack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
    }

    private func formatNumber(_ number: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: number), number: .decimal)
    }

    private func updateAppearance() {
        guard isViewLoaded, topKeysStack != nil else { return }
        let background = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.125, green: 0.129, blue: 0.137, alpha: 1)
                : .windowBackgroundColor
        }
        view.layer?.backgroundColor = statsResolvedCGColor(background, for: view)
        view.window?.backgroundColor = statsResolvedColor(background, for: view)
        heatmapView.needsDisplay = true
        overviewView.needsDisplay = true
    }

    func scrollToTop() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func rangeChanged() {
        guard let newRange = Range(rawValue: rangeControl.selectedSegment) else { return }
        range = newRange
        periodOffset = 0
        selectedDate = nil
        didSetInitialSelection = false
        refreshData()
    }

    @objc private func previousPeriod() {
        guard previousButton.isEnabled else { return }
        periodOffset += 1
        didSetInitialSelection = false
        refreshData()
    }

    @objc private func nextPeriod() {
        guard periodOffset > 0 else { return }
        periodOffset -= 1
        didSetInitialSelection = false
        refreshData()
    }

    @objc private func toggleCalendar() { setCalendarExpanded(calendarContent.isHidden) }

    @objc private func heatmapMetricChanged() {
        guard let metric = ActivityHeatmapView.Metric(rawValue: heatmapMetricControl.selectedSegment) else { return }
        heatmapView.metric = metric
        updateHeatmapMetricDescription()
    }

    @objc private func openSelectedDay() {
        guard let selectedDate else { return }
        KeyboardHeatmapWindowController.shared.show(day: selectedDate)
    }
}

private final class ActivityInsightView: NSView {
    init(title: String, value: String, detail: String, action: (() -> Void)? = nil) {
        super.init(frame: .zero)
        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.maximumNumberOfLines = 2
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .medium)
        valueLabel.lineBreakMode = .byTruncatingTail
        let detailControl: NSView
        if let action {
            detailControl = ActivityInsightButton(title: detail, action: action)
        } else {
            let label = NSTextField(wrappingLabelWithString: detail)
            label.font = .systemFont(ofSize: 10)
            label.textColor = .tertiaryLabelColor
            label.maximumNumberOfLines = 0
            detailControl = label
        }
        let stack = NSStackView(views: [titleLabel, valueLabel, detailControl])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ActivityInsightButton: NSButton {
    var onActivate: (() -> Void)?

    init(title: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title + " →"
        onActivate = action
        target = self
        self.action = #selector(activate)
        isBordered = false
        font = .systemFont(ofSize: 11)
        contentTintColor = .controlAccentColor
        alignment = .left
        toolTip = NSLocalizedString("heatmap.locateDate", comment: "")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { onActivate?() }
}
