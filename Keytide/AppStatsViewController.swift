import AppKit

final class AppStatsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var rangeControl: NSSegmentedControl!
    private var searchField: NSSearchField!
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var tableHeader: NSView!
    private var matchCountLabel: NSTextField!
    private var emptyTitleLabel: NSTextField!
    private var emptyDetailLabel: NSTextField!
    private var emptyButton: NSButton!
    private var emptyPanel: NSView!
    private var summaryTitleLabel: NSTextField!
    private var summaryPanel: StatsPanelView!
    private var keyMetric: StatsMetricView!
    private var clickMetric: StatsMetricView!
    private var scrollMetric: StatsMetricView!
    private var sortMetric: AppStatsSortMetric = .keys
    private var sortAscending = false
    private var rangeItems: [AppStats] = []
    private var visibleItems: [AppStats] = []
    private var appIconCache: [String: NSImage] = [:]

    private lazy var numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private lazy var defaultAppIcon = NSWorkspace.shared.icon(forFileType: "app")

    override func loadView() {
        let content = AppearanceTrackingView(frame: NSRect(x: 0, y: 0, width: 760, height: 680))
        content.wantsLayer = true
        content.onEffectiveAppearanceChange = { [weak self] in self?.updateAppearance() }
        view = content
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        reloadRange(preserveScroll: false)
        updateAppearance()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadRange(preserveScroll: true)
    }

    private func setupUI() {
        let titleLabel = StatsWindowStyle.title("appStats.title")
        let subtitleLabel = StatsWindowStyle.secondaryLabel(NSLocalizedString("appStats.subtitle", comment: ""), wrapping: true)
        summaryTitleLabel = StatsWindowStyle.secondaryLabel(NSLocalizedString("appStats.rangeSummary", comment: ""))

        rangeControl = NSSegmentedControl(labels: [
            NSLocalizedString("appStats.range.today", comment: ""),
            NSLocalizedString("appStats.range.week", comment: ""),
            NSLocalizedString("appStats.range.month", comment: ""),
            NSLocalizedString("appStats.range.all", comment: "")
        ], trackingMode: .selectOne, target: self, action: #selector(rangeChanged))
        rangeControl.selectedSegment = 0
        rangeControl.controlSize = .regular

        searchField = NSSearchField()
        searchField.placeholderString = NSLocalizedString("appStats.searchPlaceholder", comment: "")
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel(searchField.placeholderString)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let searchWidth = searchField.widthAnchor.constraint(equalToConstant: 220)
        searchWidth.priority = .defaultHigh
        searchWidth.isActive = true

        let toolbar = NSStackView(views: [rangeControl, NSView(), searchField])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 16

        keyMetric = StatsMetricView(title: NSLocalizedString("appStats.column.keys", comment: ""), color: .systemBlue)
        clickMetric = StatsMetricView(title: NSLocalizedString("appStats.column.clicks", comment: ""), color: .systemOrange)
        scrollMetric = StatsMetricView(title: NSLocalizedString("appStats.column.scroll", comment: ""), color: .systemTeal)
        let summaryMetrics = NSStackView(views: [keyMetric, clickMetric, scrollMetric])
        summaryMetrics.orientation = .horizontal
        summaryMetrics.distribution = .fillEqually
        summaryMetrics.spacing = 20
        summaryPanel = StatsPanelView()
        summaryPanel.addSubview(summaryMetrics)
        summaryMetrics.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            summaryMetrics.leadingAnchor.constraint(equalTo: summaryPanel.leadingAnchor, constant: 18),
            summaryMetrics.trailingAnchor.constraint(equalTo: summaryPanel.trailingAnchor, constant: -18),
            summaryMetrics.topAnchor.constraint(equalTo: summaryPanel.topAnchor, constant: 16),
            summaryMetrics.bottomAnchor.constraint(equalTo: summaryPanel.bottomAnchor, constant: -16)
        ])

        tableHeader = NSView()
        matchCountLabel = StatsWindowStyle.secondaryLabel()
        let listTitle = StatsWindowStyle.sectionTitle("appStats.listTitle")
        let listHeaderStack = NSStackView(views: [listTitle, matchCountLabel, NSView()])
        listHeaderStack.orientation = .horizontal
        listHeaderStack.alignment = .centerY
        listHeaderStack.spacing = 10
        tableHeader.addSubview(listHeaderStack)
        listHeaderStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            listHeaderStack.leadingAnchor.constraint(equalTo: tableHeader.leadingAnchor),
            listHeaderStack.trailingAnchor.constraint(equalTo: tableHeader.trailingAnchor),
            listHeaderStack.topAnchor.constraint(equalTo: tableHeader.topAnchor),
            listHeaderStack.bottomAnchor.constraint(equalTo: tableHeader.bottomAnchor, constant: -10)
        ])

        tableView = NSTableView()
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 48
        tableView.intercellSpacing = NSSize(width: 12, height: 4)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelectedApp)
        tableView.allowsEmptySelection = true
        tableView.setAccessibilityLabel(NSLocalizedString("appStats.listTitle", comment: ""))
        addTableColumn(identifier: "app", titleKey: "appStats.column.app", width: 280, sortable: false)
        addTableColumn(identifier: "keys", titleKey: "appStats.column.keys", width: 100, sortable: true)
        addTableColumn(identifier: "clicks", titleKey: "appStats.column.clicks", width: 100, sortable: true)
        addTableColumn(identifier: "scroll", titleKey: "appStats.column.scroll", width: 110, sortable: true)

        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        emptyTitleLabel = NSTextField(labelWithString: "")
        emptyTitleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        emptyTitleLabel.alignment = .center
        emptyDetailLabel = StatsWindowStyle.secondaryLabel(wrapping: true)
        emptyDetailLabel.alignment = .center
        emptyDetailLabel.maximumNumberOfLines = 3
        emptyButton = NSButton(title: "", target: self, action: #selector(emptyStateAction))
        emptyButton.bezelStyle = .rounded
        emptyButton.controlSize = .regular
        let emptyStack = NSStackView(views: [emptyTitleLabel, emptyDetailLabel, emptyButton])
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 10
        emptyPanel = NSView()
        emptyPanel.addSubview(emptyStack)
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyStack.centerXAnchor.constraint(equalTo: emptyPanel.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: emptyPanel.centerYAnchor),
            emptyStack.leadingAnchor.constraint(greaterThanOrEqualTo: emptyPanel.leadingAnchor, constant: 30),
            emptyStack.trailingAnchor.constraint(lessThanOrEqualTo: emptyPanel.trailingAnchor, constant: -30)
        ])

        let listBody = NSView()
        for child in [scrollView!, emptyPanel!] {
            child.translatesAutoresizingMaskIntoConstraints = false
            listBody.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: listBody.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: listBody.trailingAnchor),
                child.topAnchor.constraint(equalTo: listBody.topAnchor),
                child.bottomAnchor.constraint(equalTo: listBody.bottomAnchor)
            ])
        }
        let listStack = NSStackView(views: [tableHeader, listBody])
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        tableHeader.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        listBody.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        listBody.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        let contentStack = NSStackView(views: [titleLabel, subtitleLabel, toolbar, summaryTitleLabel, summaryPanel, listStack])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.setCustomSpacing(20, after: subtitleLabel)
        contentStack.setCustomSpacing(18, after: toolbar)
        contentStack.setCustomSpacing(8, after: summaryTitleLabel)
        contentStack.setCustomSpacing(20, after: summaryPanel)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStack)

        for child in [titleLabel, subtitleLabel, toolbar, summaryTitleLabel!, summaryPanel!, listStack] {
            child.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            contentStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24)
        ])
        tableView.sortDescriptors = [NSSortDescriptor(key: "keys", ascending: false)]
    }

    func refreshData() {
        guard isViewLoaded else {
            _ = view
            return
        }
        reloadRange(preserveScroll: true)
    }

    private func addTableColumn(identifier: String, titleKey: String, width: CGFloat, sortable: Bool) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = NSLocalizedString(titleKey, comment: "")
        column.width = width
        column.minWidth = identifier == "app" ? 160 : 80
        column.resizingMask = identifier == "app" ? .autoresizingMask : .userResizingMask
        if sortable {
            column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: false)
            column.headerCell.setAccessibilityLabel(column.title + ", " + NSLocalizedString("appStats.sortable", comment: ""))
        }
        tableView.addTableColumn(column)
    }

    private func reloadRange(preserveScroll: Bool) {
        let origin = scrollView.contentView.bounds.origin
        guard StatsManager.shared.appStatsEnabled else {
            rangeItems = []
            updateSummary()
            applyFilter()
            return
        }
        rangeItems = StatsManager.shared.appStatsSummary(range: selectedRange()).filter(\.hasActivity)
        updateSummary()
        applyFilter()
        if preserveScroll {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollView.contentView.setBoundsOrigin(origin)
            }
        } else {
            tableView.scrollToBeginningOfDocument(nil)
        }
    }

    private func updateSummary() {
        keyMetric.setValue(formatNumber(rangeItems.reduce(0) { $0 + $1.keyPresses }))
        clickMetric.setValue(formatNumber(rangeItems.reduce(0) { $0 + $1.totalClicks }))
        scrollMetric.setValue(formatScrollDistance(rangeItems.reduce(0) { $0 + $1.scrollDistance }))
    }

    private func applyFilter() {
        let enabled = StatsManager.shared.appStatsEnabled
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleItems = AppStatsListFilter.apply(
            items: rangeItems,
            query: query,
            displayName: displayName(for:),
            sortMetric: sortMetric,
            ascending: sortAscending
        )
        matchCountLabel.isHidden = query.isEmpty || !enabled
        matchCountLabel.stringValue = String(format: NSLocalizedString("appStats.matchCount", comment: ""), visibleItems.count, rangeItems.count)
        searchField.isEnabled = enabled
        rangeControl.isEnabled = enabled
        summaryPanel.isHidden = !enabled
        summaryTitleLabel.isHidden = !enabled
        scrollView.isHidden = !enabled || visibleItems.isEmpty
        tableHeader.isHidden = !enabled
        updateEmptyState(enabled: enabled, hasSearch: !query.isEmpty)
        tableView.reloadData()
    }

    private func updateEmptyState(enabled: Bool, hasSearch: Bool) {
        guard !enabled || visibleItems.isEmpty else {
            emptyPanel.isHidden = true
            return
        }
        emptyPanel.isHidden = false
        emptyButton.isHidden = false
        if !enabled {
            emptyTitleLabel.stringValue = NSLocalizedString("appStats.disabled", comment: "")
            emptyDetailLabel.stringValue = NSLocalizedString("appStats.disabledDetail", comment: "")
            emptyButton.title = NSLocalizedString("appStats.openSettings", comment: "")
        } else if hasSearch && !rangeItems.isEmpty {
            emptyTitleLabel.stringValue = NSLocalizedString("appStats.noSearchResults", comment: "")
            emptyDetailLabel.stringValue = NSLocalizedString("appStats.noSearchResultsDetail", comment: "")
            emptyButton.title = NSLocalizedString("appStats.clearSearch", comment: "")
        } else {
            emptyTitleLabel.stringValue = NSLocalizedString("appStats.empty", comment: "")
            emptyDetailLabel.stringValue = NSLocalizedString("appStats.emptyDetail", comment: "")
            emptyButton.isHidden = true
        }
    }

    private func selectedRange() -> StatsManager.AppStatsRange {
        [.today, .week, .month, .all][max(0, min(3, rangeControl.selectedSegment))]
    }

    private func displayName(for stats: AppStats) -> String {
        stats.displayName.isEmpty ? NSLocalizedString("appStats.unknownApp", comment: "") : stats.displayName
    }

    private func formatNumber(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatScrollDistance(_ distance: Double) -> String {
        distance >= 10000 ? String(format: "%.1f kPx", distance / 1000) : String(format: "%.0f px", distance)
    }

    private func appIcon(for bundleId: String) -> NSImage {
        if let cached = appIconCache[bundleId] { return cached }
        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = defaultAppIcon
        }
        icon.size = NSSize(width: 28, height: 28)
        appIconCache[bundleId] = icon
        return icon
    }

    private func showApp(_ app: AppStats) {
        guard StatsManager.shared.appStatsEnabled, presentedViewControllers?.isEmpty != false else { return }
        let snapshot = AppDetailPresentation(
            app: app,
            profiles: StatsManager.shared.interactionProfiles(range: selectedRange()),
            rangeTitle: rangeControl.label(forSegment: rangeControl.selectedSegment) ?? "",
            supportedHeatmapKeys: KeyboardHeatmapView.supportedKeyIDs
        )
        presentAsSheet(AppDetailViewController(snapshot: snapshot, icon: appIcon(for: app.bundleId)))
    }

    private func updateAppearance() {
        guard isViewLoaded, tableView != nil else { return }
        view.layer?.backgroundColor = statsResolvedCGColor(.windowBackgroundColor, for: view)
        view.window?.backgroundColor = statsResolvedColor(.windowBackgroundColor, for: view)
        tableView.backgroundColor = .clear
        tableView.reloadData()
    }

    @objc private func rangeChanged() { reloadRange(preserveScroll: false) }
    @objc private func searchChanged() { applyFilter() }
    @objc private func emptyStateAction() {
        if StatsManager.shared.appStatsEnabled {
            searchField.stringValue = ""
            applyFilter()
            view.window?.makeFirstResponder(searchField)
        } else {
            SettingsWindowController.shared.show()
        }
    }

    @objc private func openSelectedApp() {
        guard tableView.selectedRow >= 0, visibleItems.indices.contains(tableView.selectedRow) else { return }
        showApp(visibleItems[tableView.selectedRow])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleItems.indices.contains(row), let tableColumn else { return nil }
        let app = visibleItems[row]
        let identifier = tableColumn.identifier.rawValue
        if identifier == "app" {
            let cell = AppStatsNameCellView()
            cell.configure(name: displayName(for: app), icon: appIcon(for: app.bundleId)) { [weak self] in
                self?.showApp(app)
            }
            return cell
        }
        let value: String
        switch identifier {
        case "keys": value = formatNumber(app.keyPresses)
        case "clicks": value = formatNumber(app.totalClicks)
        default: value = formatScrollDistance(app.scrollDistance)
        }
        let label = NSTextField(labelWithString: value)
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.textColor = .labelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first else { return }
        switch descriptor.key {
        case "keys": sortMetric = .keys
        case "clicks": sortMetric = .clicks
        case "scroll": sortMetric = .scroll
        default: return
        }
        sortAscending = descriptor.ascending
        applyFilter()
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
}

private final class AppStatsNameCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailButton: NSButton

    override init(frame frameRect: NSRect) {
        let image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        detailButton = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        detailButton.isBordered = false
        detailButton.imageScaling = .scaleProportionallyDown
        detailButton.contentTintColor = .secondaryLabelColor
        detailButton.target = self
        detailButton.action = #selector(openDetails)
        detailButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(detailButton)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: detailButton.leadingAnchor, constant: -8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            detailButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailButton.widthAnchor.constraint(equalToConstant: 28),
            detailButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var actionHandler: (() -> Void)?

    func configure(name: String, icon: NSImage, action: @escaping () -> Void) {
        nameLabel.stringValue = name
        nameLabel.toolTip = name
        iconView.image = icon
        actionHandler = action
        let label = String(format: NSLocalizedString("appStats.breakdown.open", comment: ""), name)
        detailButton.toolTip = label
        detailButton.setAccessibilityLabel(label)
    }

    @objc private func openDetails() { actionHandler?() }
}
