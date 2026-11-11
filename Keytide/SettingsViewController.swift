import Cocoa
private func resolvedCGColor(_ color: NSColor, for view: NSView) -> CGColor {
    var resolved: CGColor = color.cgColor
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        resolved = color.cgColor
    }
    return resolved
}

private func resolvedColor(_ color: NSColor, for view: NSView) -> NSColor {
    let cgColor = resolvedCGColor(color, for: view)
    return NSColor(cgColor: cgColor) ?? color
}

private func resolvedCGColor(_ color: NSColor, alpha: CGFloat, for view: NSView) -> CGColor {
    var resolved: CGColor = color.cgColor
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        resolved = color.withAlphaComponent(alpha).cgColor
    }
    return resolved
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class SettingsNavigationRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawBackground(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.systemBlue.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
    }
}

final class SettingsViewController: NSViewController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private let navigation = NSTableView()
    private var pages: [[NSView]] = []
    private let pageKeys = ["general", "appearance", "notifications", "data"]
    private let pageSymbols = ["gearshape", "menubar.rectangle", "bell", "externaldrive"]
    private var selectedPage = 0

    private var scrollView: NSScrollView!
    private var documentView: NSView!
    private var contentStack: NSStackView!

    private var appIconView: NSImageView!
    private var headerTitleLabel: NSTextField!
    private var headerSubtitleLabel: NSTextField!
    private var githubButton: NSButton!

    private var menuBarLayoutPopUp: NSPopUpButton!
    private var menuBarNumbersPopUp: NSPopUpButton!
    private var menuBarPreview: MenuBarStatusView!
    private var menuBarPreviewWidth: NSLayoutConstraint!
    private var menuUIStylePopUp: NSPopUpButton!
    private var showKeyPressesButton: NSSwitch!
    private var showMouseClicksButton: NSSwitch!
    private var minimalMenuBarModeButton: NSSwitch!
    private var appStatsEnabledButton: NSSwitch!
    private var launchAtLoginButton: NSSwitch!
    private var dynamicIconColorButton: NSSwitch!
    private var dynamicIconColorStylePopUp: NSPopUpButton!
    private var dynamicIconColorStyleRow: NSStackView!
    private var dynamicIconColorWindowField: NSTextField!
    private var dynamicIconColorWindowRow: NSStackView!
    private var dynamicIconColorHelpButton: NSButton!
    private lazy var dynamicIconColorHelpPopover: NSPopover = makeDynamicIconColorHelpPopover()
    private weak var dynamicIconColorHelpContentView: NSView?
    private var helpButtonTrackingArea: NSTrackingArea?
    private var helpPopoverTrackingArea: NSTrackingArea?
    private var isHoveringHelpButton = false
    private var isHoveringHelpPopover = false
    private var resetButton: NSButton!
    private var importButton: NSButton!
    private var exportButton: NSButton!
    private var mouseDistanceCalibrationButton: NSButton!
    private var showThresholdsButton: NSSwitch!
    private var thresholdStack: NSStackView!
    private var keyPressThresholdField: NSTextField!
    private var keyPressThresholdStepper: NSStepper!
    private var clickThresholdField: NSTextField!
    private var clickThresholdStepper: NSStepper!
    private var dynamicIconOptionsContainer: NSStackView!
    private var notificationThresholdContainer: NSStackView!

    private var cardViews: [NSView] = []
    private var dividerViews: [NSView] = []
    private var optionDividerViews: [NSView] = []
    private var appearanceObservation: NSKeyValueObservation?
    private var systemThemeObserver: NSObjectProtocol?
    private var appDidBecomeActiveObserver: NSObjectProtocol?

    private let thresholdMinimum = 0
    private let thresholdMaximum = 1_000_000
    private let thresholdStep = 100.0
    private let dynamicIconColorStyleKey = "dynamicIconColorStyle"
    private let githubRepositoryURL = URL(string: "https://github.com/Xuan-lprk/KeyTide")
    private static var cachedGitHubIconImage: NSImage?

    private lazy var thresholdFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: thresholdMinimum)
        formatter.maximum = NSNumber(value: thresholdMaximum)
        return formatter
    }()

    private lazy var windowFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: 1)
        formatter.maximum = NSNumber(value: 3600)
        return formatter
    }()

    private lazy var exportFileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    // MARK: - Lifecycle

    override func loadView() {
        let mainView = AppearanceTrackingView(frame: NSRect(x: 0, y: 0, width: 840, height: 650))
        mainView.onEffectiveAppearanceChange = { [weak self] in
            self?.updateAppearance()
        }
        mainView.wantsLayer = true
        mainView.layer?.backgroundColor = resolvedCGColor(NSColor.windowBackgroundColor, for: mainView)
        view = mainView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        updateState()
        updateAppearance()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateAppearance()
            }
        }
        systemThemeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateAppearance()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.updateAppearance()
            }
        }
        appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateAppearance()
        }

    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateState()
        updateAppearance()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(nil)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateHelpButtonTrackingArea()
        updateHelpPopoverTrackingArea()
    }

    deinit {
        appearanceObservation = nil
        if let observer = systemThemeObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let observer = appDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }

    }

    // MARK: - UI

    private func setupUI() {
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebar)
        let sidebarStack = NSStackView()
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 20
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarStack)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        view.addSubview(scrollView)

        documentView = SettingsDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)

        appIconView = NSImageView()
        appIconView.image = NSApp.applicationIconImage
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        appIconView.widthAnchor.constraint(equalToConstant: 44).isActive = true
        appIconView.heightAnchor.constraint(equalToConstant: 44).isActive = true

        headerTitleLabel = NSTextField(labelWithString: NSLocalizedString("settings.windowTitle", comment: ""))
        headerTitleLabel.font = NSFont.systemFont(ofSize: 26, weight: .bold)

        headerSubtitleLabel = NSTextField(wrappingLabelWithString: NSLocalizedString("settings.header.subtitle", comment: ""))
        headerSubtitleLabel.font = NSFont.systemFont(ofSize: 12)
        headerSubtitleLabel.textColor = .secondaryLabelColor

        let versionString: String = {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
            return "v\(version) (\(build))"
        }()
        let versionLabel = NSTextField(labelWithString: versionString)
        versionLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        versionLabel.textColor = .tertiaryLabelColor

        githubButton = makeSymbolButton(
            systemName: "chevron.left.forwardslash.chevron.right",
            fallbackTitle: NSLocalizedString("settings.github", comment: ""),
            pointSize: 14,
            weight: .semibold,
            action: #selector(openGitHubRepository)
        )
        githubButton.toolTip = NSLocalizedString("settings.github.tooltip", comment: "")
        githubButton.setAccessibilityLabel(NSLocalizedString("settings.github", comment: ""))
        githubButton.imageScaling = .scaleProportionallyDown
        if let hoverButton = githubButton as? HoverIconButton {
            hoverButton.showsHoverBackground = false
            hoverButton.padding = 4
            hoverButton.cornerRadius = 6
        }
        NSLayoutConstraint.activate([
            githubButton.widthAnchor.constraint(equalToConstant: 28),
            githubButton.heightAnchor.constraint(equalToConstant: 28)
        ])
        applyBundledGitHubIconIfNeeded()

        let headerTextStack = NSStackView(views: [headerTitleLabel, headerSubtitleLabel])
        headerTextStack.orientation = .vertical
        headerTextStack.alignment = .leading
        headerTextStack.spacing = 2
        headerTextStack.translatesAutoresizingMaskIntoConstraints = false

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let headerStack = NSStackView(views: [headerTextStack, headerSpacer, githubButton])
        let brand = NSTextField(labelWithString: "Keytide")
        brand.font = .systemFont(ofSize: 18, weight: .semibold)
        let identity = NSStackView(views: [appIconView, brand])
        identity.orientation = .horizontal
        identity.spacing = 10
        identity.alignment = .centerY
        sidebarStack.addArrangedSubview(identity)
        navigation.frame = NSRect(x: 0, y: 0, width: 162, height: 190)
        navigation.autoresizingMask = [.width]
        navigation.headerView = nil
        navigation.style = .plain
        navigation.backgroundColor = .clear
        navigation.rowHeight = 36
        navigation.intercellSpacing = NSSize(width: 0, height: 6)
        navigation.selectionHighlightStyle = .none
        navigation.allowsEmptySelection = false
        navigation.focusRingType = .none
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("category"))
        navigation.addTableColumn(column)
        navigation.dataSource = self
        navigation.delegate = self
        let navigationScroll = NSScrollView()
        navigationScroll.drawsBackground = false
        navigationScroll.documentView = navigation
        navigationScroll.hasVerticalScroller = false
        navigationScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarStack.addArrangedSubview(navigationScroll)
        navigationScroll.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
        navigationScroll.heightAnchor.constraint(equalToConstant: 190).isActive = true
        let sidebarFooter = NSTextField(wrappingLabelWithString: NSLocalizedString("settings.localOnly", comment: ""))
        sidebarFooter.font = .systemFont(ofSize: 11)
        sidebarFooter.textColor = .secondaryLabelColor
        sidebarStack.addArrangedSubview(sidebarFooter)
        sidebarStack.addArrangedSubview(versionLabel)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 190),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            sidebarStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 26)
        ])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 12
        addArrangedSubviewFillingWidth(headerStack, to: contentStack)
        contentStack.setCustomSpacing(20, after: headerStack)

        showKeyPressesButton = makeSwitch(action: #selector(toggleShowKeyPresses))
        showMouseClicksButton = makeSwitch(action: #selector(toggleShowMouseClicks))
        minimalMenuBarModeButton = makeSwitch(action: #selector(toggleMinimalMenuBarMode))
        appStatsEnabledButton = makeSwitch(action: #selector(toggleAppStatsEnabled))
        launchAtLoginButton = makeSwitch(action: #selector(toggleLaunchAtLogin))
        showThresholdsButton = makeSwitch(action: #selector(toggleShowThresholds))
        dynamicIconColorButton = makeSwitch(action: #selector(toggleDynamicIconColor))

        dynamicIconColorHelpButton = NSButton()
        dynamicIconColorHelpButton.bezelStyle = .helpButton
        dynamicIconColorHelpButton.title = ""
        dynamicIconColorHelpButton.controlSize = .mini
        dynamicIconColorHelpButton.translatesAutoresizingMaskIntoConstraints = false
        dynamicIconColorHelpButton.widthAnchor.constraint(equalToConstant: 14).isActive = true
        dynamicIconColorHelpButton.heightAnchor.constraint(equalToConstant: 14).isActive = true

        menuUIStylePopUp = NSPopUpButton()
        menuUIStylePopUp.addItems(withTitles: [
            NSLocalizedString("settings.uiStyle.standard", comment: ""),
            NSLocalizedString("settings.uiStyle.geek", comment: "")
        ])
        menuUIStylePopUp.target = self
        menuUIStylePopUp.action = #selector(changeMenuUIStyle)
        menuUIStylePopUp.setAccessibilityLabel(NSLocalizedString("settings.uiStyle", comment: ""))
        menuBarLayoutPopUp = NSPopUpButton()
        menuBarLayoutPopUp.addItems(withTitles: [NSLocalizedString("settings.menuDisplay.stacked", comment: ""), NSLocalizedString("settings.menuDisplay.single", comment: "")])
        menuBarNumbersPopUp = NSPopUpButton()
        menuBarNumbersPopUp.addItems(withTitles: [NSLocalizedString("settings.menuDisplay.compact", comment: ""), NSLocalizedString("settings.menuDisplay.full", comment: "")])
        for control in [menuBarLayoutPopUp!, menuBarNumbersPopUp!] {
            control.target = self
            control.action = #selector(changeMenuBarDisplay)
        }
        menuBarLayoutPopUp.setAccessibilityLabel(NSLocalizedString("settings.menuDisplay.layout", comment: ""))
        menuBarNumbersPopUp.setAccessibilityLabel(NSLocalizedString("settings.menuDisplay.numbers", comment: ""))
        menuBarPreview = MenuBarStatusView()
        menuBarPreview.translatesAutoresizingMaskIntoConstraints = false
        menuBarPreview.setAccessibilityRole(.image)
        menuBarPreview.setAccessibilityLabel(NSLocalizedString("settings.menuDisplay.preview", comment: ""))
        menuBarPreviewWidth = menuBarPreview.widthAnchor.constraint(equalToConstant: 100)
        menuBarPreviewWidth.isActive = true
        menuBarPreview.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let menuBarStack = makeOptionSeparatedStack([
            makeLabeledRow(title: NSLocalizedString("settings.uiStyle", comment: ""), control: menuUIStylePopUp),
            makeSwitchRow(titleKey: "setting.showKeyPresses", toggle: showKeyPressesButton),
            makeSwitchRow(titleKey: "setting.showMouseClicks", toggle: showMouseClicksButton),
            makeSwitchRow(titleKey: "setting.minimalMenuBarMode", toggle: minimalMenuBarModeButton),
            makeLabeledRow(title: NSLocalizedString("settings.menuDisplay.layout", comment: ""), control: menuBarLayoutPopUp),
            makeLabeledRow(title: NSLocalizedString("settings.menuDisplay.numbers", comment: ""), control: menuBarNumbersPopUp),
            makeLabeledRow(title: NSLocalizedString("settings.menuDisplay.preview", comment: ""), control: menuBarPreview)
        ])

        let menuBarSection = makeSection(titleKey: "settings.section.menuBar", content: menuBarStack)

        let dynamicIconRow = makeSwitchRow(titleKey: "settings.dynamicIconColor",
                                           toggle: dynamicIconColorButton,
                                           accessory: dynamicIconColorHelpButton)

        dynamicIconColorStylePopUp = NSPopUpButton()
        dynamicIconColorStylePopUp.controlSize = .small
        dynamicIconColorStylePopUp.font = NSFont.systemFont(ofSize: 12)
        let iconStyleTitle = NSLocalizedString("settings.dynamicIconColorStyle.icon", comment: "")
        let dotStyleTitle = NSLocalizedString("settings.dynamicIconColorStyle.dot", comment: "")
        dynamicIconColorStylePopUp.addItems(withTitles: [iconStyleTitle, dotStyleTitle])
        dynamicIconColorStylePopUp.item(at: 0)?.representedObject = DynamicIconColorStyle.icon.rawValue
        dynamicIconColorStylePopUp.item(at: 1)?.representedObject = DynamicIconColorStyle.dot.rawValue
        dynamicIconColorStylePopUp.target = self
        dynamicIconColorStylePopUp.action = #selector(dynamicIconColorStyleChanged)

        let styleRow = makeLabeledRow(title: NSLocalizedString("settings.dynamicIconColorStyle", comment: ""),
                                      control: dynamicIconColorStylePopUp)
        dynamicIconColorStyleRow = styleRow

        dynamicIconColorWindowField = NSTextField()
        dynamicIconColorWindowField.controlSize = .small
        dynamicIconColorWindowField.font = NSFont.systemFont(ofSize: 12)
        dynamicIconColorWindowField.formatter = windowFormatter
        dynamicIconColorWindowField.target = self
        dynamicIconColorWindowField.action = #selector(dynamicIconColorWindowChanged)
        dynamicIconColorWindowField.delegate = self
        dynamicIconColorWindowField.translatesAutoresizingMaskIntoConstraints = false
        dynamicIconColorWindowField.widthAnchor.constraint(equalToConstant: 56).isActive = true

        let windowRow = makeLabeledRow(title: NSLocalizedString("settings.dynamicIconColorWindow", comment: ""),
                                       control: dynamicIconColorWindowField)
        dynamicIconColorWindowRow = windowRow

        let dynamicSubStack = makeOptionSeparatedStack([
            dynamicIconColorStyleRow,
            dynamicIconColorWindowRow
        ], spacing: 6)
        let dynamicIndentedStack = makeIndentedContainer(dynamicSubStack, indent: 22)

        let trackingStack = makeVerticalStack(spacing: 8)
        let appStatsRow = makeSwitchRow(titleKey: "setting.appStatsEnabled", toggle: appStatsEnabledButton)
        let launchRow = makeSwitchRow(titleKey: "button.launchAtLogin", toggle: launchAtLoginButton)
        addArrangedSubviewFillingWidth(appStatsRow, to: trackingStack)
        addArrangedSubviewFillingWidth(makeOptionDividerContainer(), to: trackingStack)
        addArrangedSubviewFillingWidth(launchRow, to: trackingStack)

        dynamicIconOptionsContainer = makeVerticalStack(spacing: 6)
        addArrangedSubviewFillingWidth(makeOptionDividerContainer(), to: dynamicIconOptionsContainer)
        addArrangedSubviewFillingWidth(dynamicIndentedStack, to: dynamicIconOptionsContainer)
        let inputFeedback = makeVerticalStack(spacing: 8)
        addArrangedSubviewFillingWidth(dynamicIconRow, to: inputFeedback)
        addArrangedSubviewFillingWidth(dynamicIconOptionsContainer, to: inputFeedback)
        let feedbackSection = makeSection(titleKey: "settings.section.feedback", content: inputFeedback)

        let trackingSection = makeSection(titleKey: "settings.section.tracking", content: trackingStack)

        keyPressThresholdField = makeThresholdField()
        keyPressThresholdStepper = makeThresholdStepper(action: #selector(keyPressThresholdStepperChanged))
        clickThresholdField = makeThresholdField()
        clickThresholdStepper = makeThresholdStepper(action: #selector(clickThresholdStepperChanged))

        let keyThresholdRow = makeThresholdRow(
            title: NSLocalizedString("setting.notifyKeyThreshold", comment: ""),
            field: keyPressThresholdField,
            stepper: keyPressThresholdStepper
        )
        let clickThresholdRow = makeThresholdRow(
            title: NSLocalizedString("setting.notifyClickThreshold", comment: ""),
            field: clickThresholdField,
            stepper: clickThresholdStepper
        )

        thresholdStack = makeOptionSeparatedStack([
            keyThresholdRow,
            clickThresholdRow
        ], spacing: 6)

        let notificationStack = makeVerticalStack(spacing: 8)
        addArrangedSubviewFillingWidth(makeSwitchRow(titleKey: "setting.notificationsEnabled", toggle: showThresholdsButton), to: notificationStack)
        let thresholdIndentStack = makeIndentedContainer(thresholdStack, indent: 22)
        notificationThresholdContainer = makeVerticalStack(spacing: 6)
        addArrangedSubviewFillingWidth(makeOptionDividerContainer(), to: notificationThresholdContainer)
        addArrangedSubviewFillingWidth(thresholdIndentStack, to: notificationThresholdContainer)
        addArrangedSubviewFillingWidth(notificationThresholdContainer, to: notificationStack)

        let notificationSection = makeSection(titleKey: "settings.section.notifications", content: notificationStack)

        mouseDistanceCalibrationButton = NSButton(title: NSLocalizedString("settings.mouseDistanceCalibration", comment: ""),
                                                  target: self,
                                                  action: #selector(calibrateMouseDistance))
        mouseDistanceCalibrationButton.bezelStyle = .rounded
        mouseDistanceCalibrationButton.controlSize = .regular

        exportButton = NSButton(title: NSLocalizedString("button.exportData", comment: ""),
                                target: self,
                                action: #selector(exportData))
        exportButton.bezelStyle = .rounded
        exportButton.controlSize = .regular

        importButton = NSButton(title: NSLocalizedString("button.importData", comment: ""),
                                target: self,
                                action: #selector(importData))
        importButton.bezelStyle = .rounded
        importButton.controlSize = .regular

        resetButton = NSButton(title: NSLocalizedString("button.reset", comment: ""),
                               target: self,
                               action: #selector(resetStats))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .regular
        resetButton.bezelColor = nil
        resetButton.contentTintColor = nil

        let actionStack = makeVerticalStack(spacing: 14)
        addArrangedSubviewFillingWidth(makeActionRow("settings.data.calibration", help: "settings.data.calibrationHelp", button: mouseDistanceCalibrationButton), to: actionStack)
        addArrangedSubviewFillingWidth(makeOptionDividerContainer(), to: actionStack)
        let transferButtons = NSStackView(views: [importButton, exportButton])
        transferButtons.spacing = 8
        addArrangedSubviewFillingWidth(makeLabeledRow(title: NSLocalizedString("settings.data.transfer", comment: ""), control: transferButtons), to: actionStack)
        let transferHelp = NSTextField(wrappingLabelWithString: NSLocalizedString("settings.data.transferHelp", comment: ""))
        transferHelp.font = .systemFont(ofSize: 11)
        transferHelp.textColor = .secondaryLabelColor
        addArrangedSubviewFillingWidth(transferHelp, to: actionStack)
        let resetSection = makeSection(titleKey: "settings.data.reset", content: makeActionRow("settings.data.reset", help: "settings.data.resetHelp", button: resetButton))
        resetButton.contentTintColor = .systemRed

        let actionSection = makeSection(titleKey: "settings.section.data", content: actionStack)

        pages = [[trackingSection], [menuBarSection, feedbackSection], [notificationSection], [actionSection, resetSection]]
        navigation.reloadData()
        navigation.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showPage(0)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 28),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -28),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24)
        ])
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SettingsNavigationRow()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { pageKeys.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: NSLocalizedString("settings.navigation." + pageKeys[row], comment: ""))
        let icon = NSImageView(image: NSImage(systemSymbolName: pageSymbols[row], accessibilityDescription: nil)!)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        for child in [icon, label] { child.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(child) }
        cell.textField = label; cell.imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.widthAnchor.constraint(equalToConstant: 17), icon.heightAnchor.constraint(equalToConstant: 17),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard navigation.selectedRow >= 0 else { return }
        showPage(navigation.selectedRow)
    }

    private func showPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        selectedPage = index
        // The first arranged subview is the shared page header.
        for child in Array(contentStack.arrangedSubviews.dropFirst()) {
            contentStack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        headerTitleLabel.stringValue = NSLocalizedString("settings.page." + pageKeys[index], comment: "")
        headerSubtitleLabel.stringValue = NSLocalizedString("settings.page." + pageKeys[index] + ".help", comment: "")
        for section in pages[index] { addArrangedSubviewFillingWidth(section, to: contentStack) }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func makeActionRow(_ title: String, help: String, button: NSButton) -> NSView {
        let text = NSTextField(wrappingLabelWithString: NSLocalizedString(title, comment: ""))
        text.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(wrappingLabelWithString: NSLocalizedString(help, comment: ""))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [text, detail])
        labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 4
        return makeLabeledRowView(labels: labels, control: button)
    }

    private func makeLabeledRowView(labels: NSView, control: NSView) -> NSView {
        let row = NSStackView(views: [labels, NSView(), control])
        row.orientation = .horizontal; row.spacing = 16; row.alignment = .centerY
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }

    private func makeSection(titleKey: String, content: NSView) -> NSView {
        let titleLabel = makeSectionTitleLabel(NSLocalizedString(titleKey, comment: ""))

        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])

        cardViews.append(card)

        let wrapper = makeVerticalStack(spacing: 6)
        wrapper.addArrangedSubview(titleLabel)
        addArrangedSubviewFillingWidth(card, to: wrapper)

        return wrapper
    }

    private func makeSectionTitleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    private func makeDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        return divider
    }

    private func makeOptionDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        optionDividerViews.append(divider)
        return divider
    }

    private func makeOptionDividerContainer(inset: CGFloat = 0) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let divider = makeOptionDivider()
        container.addSubview(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func makeRowLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        return label
    }

    private func makeSwitch(action: Selector) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = action
        toggle.translatesAutoresizingMaskIntoConstraints = false
        return toggle
    }

    private func makeSwitchRow(titleKey: String, toggle: NSSwitch, accessory: NSView? = nil) -> NSStackView {
        let label = makeRowLabel(NSLocalizedString(titleKey, comment: ""))
        toggle.setAccessibilityLabel(label.stringValue)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row: NSStackView
        if let accessory = accessory {
            let leadingStack = NSStackView(views: [label, accessory])
            leadingStack.orientation = .horizontal
            leadingStack.alignment = .centerY
            leadingStack.spacing = 6

            row = NSStackView(views: [leadingStack, spacer, toggle])
        } else {
            row = NSStackView(views: [label, spacer, toggle])
        }
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makeLabeledRow(title: String, control: NSView) -> NSStackView {
        let label = makeRowLabel(title)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [label, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makeSymbolButton(systemName: String,
                                  fallbackTitle: String,
                                  pointSize: CGFloat? = nil,
                                  weight: NSFont.Weight = .regular,
                                  action: Selector) -> NSButton {
        var image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
        if let pointSize = pointSize, let baseImage = image {
            let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            image = baseImage.withSymbolConfiguration(configuration)
        }

        if let image = image {
            let button = HoverIconButton(image: image, target: self, action: action)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .labelColor
            button.translatesAutoresizingMaskIntoConstraints = false
            return button
        }

        let button = NSButton(title: fallbackTitle, target: self, action: action)
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func applyBundledGitHubIconIfNeeded() {
        if let cachedImage = Self.cachedGitHubIconImage {
            applyGitHubButtonImage(cachedImage)
            return
        }
        guard let image = makeGitHubSVGIcon() else { return }
        image.isTemplate = true
        Self.cachedGitHubIconImage = image
        applyGitHubButtonImage(image)
    }

    private func makeGitHubSVGIcon() -> NSImage? {
        let svg = """
        <svg aria-hidden="true" focusable="false" class="octicon octicon-mark-github" viewBox="0 0 24 24" width="32" height="32" fill="currentColor" display="inline-block" overflow="visible" style="vertical-align:text-bottom" xmlns="http://www.w3.org/2000/svg">
          <path d="M12 1C5.923 1 1 5.923 1 12c0 4.867 3.149 8.979 7.521 10.436.55.096.756-.233.756-.522 0-.262-.013-1.128-.013-2.049-2.764.509-3.479-.674-3.699-1.292-.124-.317-.66-1.293-1.127-1.554-.385-.207-.936-.715-.014-.729.866-.014 1.485.797 1.691 1.128.99 1.663 2.571 1.196 3.204.907.096-.715.385-1.196.701-1.471-2.448-.275-5.005-1.224-5.005-5.432 0-1.196.426-2.186 1.128-2.956-.111-.275-.496-1.402.11-2.915 0 0 .921-.288 3.024 1.128a10.193 10.193 0 0 1 2.75-.371c.936 0 1.871.123 2.75.371 2.104-1.43 3.025-1.128 3.025-1.128.605 1.513.221 2.64.111 2.915.701.77 1.127 1.747 1.127 2.956 0 4.222-2.571 5.157-5.019 5.432.399.344.743 1.004.743 2.035 0 1.471-.014 2.654-.014 3.025 0 .289.206.632.756.522C19.851 20.979 23 16.854 23 12c0-6.077-4.922-11-11-11Z"></path>
        </svg>
        """
        guard let data = svg.data(using: .utf8) else { return nil }
        return NSImage(data: data)
    }

    private func applyGitHubButtonImage(_ image: NSImage) {
        githubButton.image = image
        githubButton.imagePosition = .imageOnly
        githubButton.contentTintColor = .labelColor
    }

    private func makeIndentedContainer(_ content: NSView, indent: CGFloat) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: indent),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func makeVerticalStack(spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeOptionSeparatedStack(_ rows: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = makeVerticalStack(spacing: spacing)
        for (index, row) in rows.enumerated() {
            addArrangedSubviewFillingWidth(row, to: stack)
            if index < rows.count - 1 {
                addArrangedSubviewFillingWidth(makeOptionDividerContainer(), to: stack)
            }
        }
        return stack
    }

    private func addArrangedSubviewFillingWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func updateAppearance() {
        view.layer?.backgroundColor = resolvedCGColor(NSColor.windowBackgroundColor, for: view)
        view.window?.backgroundColor = NSColor.windowBackgroundColor
        let isDarkMode = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let shadowColor = NSColor.black.withAlphaComponent(isDarkMode ? 0.2 : 0.07)
        let dividerAlpha: CGFloat = isDarkMode ? 0.2 : 0.12
        let optionDividerAlpha: CGFloat = isDarkMode ? 0.24 : 0.14
        let darkSectionBaseColor = NSColor(
            srgbRed: 39.0 / 255.0,
            green: 43.0 / 255.0,
            blue: 45.0 / 255.0,
            alpha: 1.0
        )

        for card in cardViews {
            guard let layer = card.layer else { continue }
            layer.cornerRadius = 12
            layer.masksToBounds = false
            if isDarkMode {
                layer.backgroundColor = resolvedCGColor(darkSectionBaseColor, for: view)
            } else {
                layer.backgroundColor = resolvedCGColor(NSColor.controlBackgroundColor, alpha: 0.88, for: view)
            }
            layer.borderWidth = 0.5
            layer.borderColor = resolvedCGColor(.separatorColor, alpha: 0.25, for: view)
            layer.shadowColor = resolvedCGColor(shadowColor, for: view)
            layer.shadowOpacity = 0
            layer.shadowRadius = 8
            layer.shadowOffset = NSSize(width: 0, height: -1)
        }

        for divider in dividerViews {
            divider.layer?.backgroundColor = resolvedCGColor(NSColor.separatorColor, alpha: dividerAlpha, for: view)
        }

        for divider in optionDividerViews {
            divider.layer?.backgroundColor = resolvedCGColor(NSColor.separatorColor, alpha: optionDividerAlpha, for: view)
        }
    }

    // MARK: - State

    @objc private func changeMenuUIStyle() {
        let style = MenuUIStyle.allCases[menuUIStylePopUp.indexOfSelectedItem]
        UserDefaults.standard.set(style.rawValue, forKey: MenuUIStyle.defaultsKey)
        NotificationCenter.default.post(name: .menuUIStyleDidChange, object: nil)
    }

    @objc private func changeMenuBarDisplay() {
        UserDefaults.standard.set(menuBarLayoutPopUp.indexOfSelectedItem == 1, forKey: MenuBarDisplayPreferences.singleLineKey)
        UserDefaults.standard.set(menuBarNumbersPopUp.indexOfSelectedItem == 1, forKey: MenuBarDisplayPreferences.fullNumbersKey)
        updateMenuBarPreview()
        StatsManager.shared.menuBarUpdateHandler?()
    }

    private func updateMenuBarPreview() {
        let single = UserDefaults.standard.bool(forKey: MenuBarDisplayPreferences.singleLineKey)
        let full = UserDefaults.standard.bool(forKey: MenuBarDisplayPreferences.fullNumbersKey)
        menuBarLayoutPopUp.selectItem(at: single ? 1 : 0)
        menuBarNumbersPopUp.selectItem(at: full ? 1 : 0)
        menuBarPreview.configure(singleLine: single, fullNumbers: full)
        menuBarPreview.update(keysText: StatsManager.shared.showKeyPressesInMenuBar ? MenuBarDisplayPreferences.number(12856, full: full) : "",
                              clicksText: StatsManager.shared.showMouseClicksInMenuBar ? MenuBarDisplayPreferences.number(3210, full: full) : "")
        menuBarPreview.updateIconColor(nil, style: .icon, isMinimalMode: StatsManager.shared.minimalMenuBarMode, showsColorDot: false)
        menuBarPreviewWidth.constant = menuBarPreview.intrinsicContentSize.width
    }

    private func updateState() {
        updateMenuBarPreview()
        menuUIStylePopUp.selectItem(at: MenuUIStyle.allCases.firstIndex(of: MenuUIStyle.current) ?? 0)
        showKeyPressesButton.state = StatsManager.shared.showKeyPressesInMenuBar ? .on : .off
        showMouseClicksButton.state = StatsManager.shared.showMouseClicksInMenuBar ? .on : .off
        minimalMenuBarModeButton.state = StatsManager.shared.minimalMenuBarMode ? .on : .off
        appStatsEnabledButton.state = StatsManager.shared.appStatsEnabled ? .on : .off
        launchAtLoginButton.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off
        dynamicIconColorButton.state = StatsManager.shared.enableDynamicIconColor ? .on : .off
        updateDynamicIconColorStyleSelection()
        let notificationsEnabled = StatsManager.shared.notificationsEnabled
        showThresholdsButton.state = notificationsEnabled ? .on : .off
        notificationThresholdContainer.isHidden = !notificationsEnabled
        updateThresholdUI()
    }

    private func updateDynamicIconColorStyleSelection() {
        let isMinimalMode = StatsManager.shared.minimalMenuBarMode
        if isMinimalMode {
            UserDefaults.standard.set(DynamicIconColorStyle.dot.rawValue, forKey: dynamicIconColorStyleKey)
        }
        let styleValue = UserDefaults.standard.string(forKey: dynamicIconColorStyleKey) ?? DynamicIconColorStyle.icon.rawValue
        let style = DynamicIconColorStyle(rawValue: styleValue) ?? .icon
        if let item = dynamicIconColorStylePopUp.itemArray.first(where: { ($0.representedObject as? String) == style.rawValue }) {
            dynamicIconColorStylePopUp.select(item)
        }
        let isEnabled = StatsManager.shared.enableDynamicIconColor
        dynamicIconColorStylePopUp.isEnabled = isEnabled && !isMinimalMode
        dynamicIconColorStyleRow.isHidden = false
        dynamicIconColorWindowRow.isHidden = false
        dynamicIconOptionsContainer.isHidden = !isEnabled
        dynamicIconColorWindowField.doubleValue = StatsManager.shared.dynamicIconColorWindow
    }

    private func makeDynamicIconColorHelpPopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 520)
        popover.contentViewController = makeDynamicIconColorHelpViewController()
        return popover
    }

    private func makeDynamicIconColorHelpViewController() -> NSViewController {
        let viewController = NSViewController()
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        viewController.view = container
        dynamicIconColorHelpContentView = container
        updateHelpPopoverTrackingArea()

        let titleLabel = NSTextField(labelWithString: NSLocalizedString("settings.dynamicIconColorHelp.title", comment: ""))
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let bodyLabel = NSTextField(wrappingLabelWithString: NSLocalizedString("settings.dynamicIconColorHelp.body", comment: ""))
        bodyLabel.font = NSFont.systemFont(ofSize: 12)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        let imageGridStack = NSStackView()
        imageGridStack.orientation = .vertical
        imageGridStack.alignment = .centerX
        imageGridStack.spacing = 8
        imageGridStack.translatesAutoresizingMaskIntoConstraints = false

        let imageNames = [
            "DynamicColorTip3",
            "DynamicColorTip2",
            "DynamicColorTip1",
            "DynamicColorTip6",
            "DynamicColorTip5",
            "DynamicColorTip4"
        ]
        var currentRow: NSStackView?
        for (index, name) in imageNames.enumerated() {
            if index % 3 == 0 {
                let row = NSStackView()
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 8
                row.translatesAutoresizingMaskIntoConstraints = false
                imageGridStack.addArrangedSubview(row)
                currentRow = row
            }
            guard let image = NSImage(named: name) else { continue }
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.widthAnchor.constraint(equalToConstant: 64).isActive = true
            imageView.heightAnchor.constraint(lessThanOrEqualToConstant: 44).isActive = true
            currentRow?.addArrangedSubview(imageView)
        }

        let contentStack = NSStackView(views: [titleLabel, bodyLabel, imageGridStack])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            contentStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])

        return viewController
    }

    private func updateHelpButtonTrackingArea() {
        if let trackingArea = helpButtonTrackingArea {
            dynamicIconColorHelpButton.removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: dynamicIconColorHelpButton.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: ["dynamicIconColorHelpButton": true]
        )
        dynamicIconColorHelpButton.addTrackingArea(trackingArea)
        helpButtonTrackingArea = trackingArea
    }

    private func updateHelpPopoverTrackingArea() {
        guard let container = dynamicIconColorHelpContentView else { return }
        if let trackingArea = helpPopoverTrackingArea {
            container.removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: container.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: ["dynamicIconColorHelpPopover": true]
        )
        container.addTrackingArea(trackingArea)
        helpPopoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea?.userInfo?["dynamicIconColorHelpButton"] as? Bool == true {
            isHoveringHelpButton = true
            showDynamicIconColorHelpPopover()
            return
        }
        if event.trackingArea?.userInfo?["dynamicIconColorHelpPopover"] as? Bool == true {
            isHoveringHelpPopover = true
            return
        }
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea?.userInfo?["dynamicIconColorHelpButton"] as? Bool == true {
            isHoveringHelpButton = false
            scheduleHelpPopoverCloseIfNeeded()
            return
        }
        if event.trackingArea?.userInfo?["dynamicIconColorHelpPopover"] as? Bool == true {
            isHoveringHelpPopover = false
            scheduleHelpPopoverCloseIfNeeded()
            return
        }
        super.mouseExited(with: event)
    }

    private func showDynamicIconColorHelpPopover() {
        guard let button = dynamicIconColorHelpButton else { return }
        if dynamicIconColorHelpPopover.isShown { return }
        dynamicIconColorHelpPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func scheduleHelpPopoverCloseIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            if !self.isHoveringHelpButton && !self.isHoveringHelpPopover {
                self.dynamicIconColorHelpPopover.performClose(nil)
            }
        }
    }

    // MARK: - 通知阈值

    private enum ThresholdType {
        case keyPress
        case click
    }

    private func makeThresholdField() -> NSTextField {
        let field = NSTextField()
        field.controlSize = .small
        field.font = NSFont.systemFont(ofSize: 12)
        field.alignment = .right
        field.formatter = thresholdFormatter
        field.target = self
        field.action = #selector(thresholdFieldEdited)
        field.delegate = self
        return field
    }

    private func makeThresholdStepper(action: Selector) -> NSStepper {
        let stepper = NSStepper()
        stepper.controlSize = .small
        stepper.minValue = Double(thresholdMinimum)
        stepper.maxValue = Double(thresholdMaximum)
        stepper.increment = thresholdStep
        stepper.target = self
        stepper.action = action
        return stepper
    }

    private func makeThresholdRow(title: String, field: NSTextField, stepper: NSStepper) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13)

        let unitLabel = NSTextField(labelWithString: NSLocalizedString("setting.notifyUnit", comment: ""))
        unitLabel.textColor = .secondaryLabelColor

        field.translatesAutoresizingMaskIntoConstraints = false
        stepper.translatesAutoresizingMaskIntoConstraints = false

        field.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let trailingStack = NSStackView(views: [field, unitLabel, stepper])
        trailingStack.orientation = .horizontal
        trailingStack.alignment = .centerY
        trailingStack.spacing = 6

        let row = NSStackView(views: [titleLabel, spacer, trailingStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func updateThresholdUI() {
        let keyThreshold = StatsManager.shared.keyPressNotifyThreshold
        let clickThreshold = StatsManager.shared.clickNotifyThreshold
        keyPressThresholdField.stringValue = "\(keyThreshold)"
        clickThresholdField.stringValue = "\(clickThreshold)"
        keyPressThresholdStepper.integerValue = keyThreshold
        clickThresholdStepper.integerValue = clickThreshold
    }

    private func clampThreshold(_ value: Int) -> Int {
        return min(max(value, thresholdMinimum), thresholdMaximum)
    }

    private func applyThreshold(_ value: Int, for type: ThresholdType) {
        let clamped = clampThreshold(value)
        switch type {
        case .keyPress:
            if StatsManager.shared.keyPressNotifyThreshold != clamped {
                StatsManager.shared.keyPressNotifyThreshold = clamped
            }
            keyPressThresholdField.stringValue = "\(clamped)"
            keyPressThresholdStepper.integerValue = clamped
        case .click:
            if StatsManager.shared.clickNotifyThreshold != clamped {
                StatsManager.shared.clickNotifyThreshold = clamped
            }
            clickThresholdField.stringValue = "\(clamped)"
            clickThresholdStepper.integerValue = clamped
        }
        requestNotificationPermissionIfNeeded()
    }

    private func requestNotificationPermissionIfNeeded() {
        let manager = StatsManager.shared
        guard manager.notificationsEnabled else { return }
        guard manager.keyPressNotifyThreshold > 0 || manager.clickNotifyThreshold > 0 else { return }
        NotificationManager.shared.requestAuthorizationIfNeeded()
    }

    @objc private func keyPressThresholdStepperChanged() {
        applyThreshold(keyPressThresholdStepper.integerValue, for: .keyPress)
    }

    @objc private func clickThresholdStepperChanged() {
        applyThreshold(clickThresholdStepper.integerValue, for: .click)
    }

    @objc private func dynamicIconColorWindowChanged(_ sender: NSTextField) {
        let value = windowFormatter.number(from: sender.stringValue)?.doubleValue ?? 3.0
        StatsManager.shared.dynamicIconColorWindow = value
    }

    @objc private func thresholdFieldEdited(_ sender: NSTextField) {
        let value = thresholdFormatter.number(from: sender.stringValue)?.intValue ?? 0
        if sender == keyPressThresholdField {
            applyThreshold(value, for: .keyPress)
        } else if sender == clickThresholdField {
            applyThreshold(value, for: .click)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field == dynamicIconColorWindowField {
            dynamicIconColorWindowChanged(field)
        } else {
            thresholdFieldEdited(field)
        }
    }

    // MARK: - Actions

    @objc private func toggleShowThresholds() {
        let enabled = showThresholdsButton.state == .on
        StatsManager.shared.notificationsEnabled = enabled
        notificationThresholdContainer.isHidden = !enabled
        if enabled {
            requestNotificationPermissionIfNeeded()
        }
    }

    @objc private func toggleShowKeyPresses() {
        StatsManager.shared.showKeyPressesInMenuBar = (showKeyPressesButton.state == .on)
        updateMenuBarPreview()
    }

    @objc private func toggleShowMouseClicks() {
        StatsManager.shared.showMouseClicksInMenuBar = (showMouseClicksButton.state == .on)
        updateMenuBarPreview()
    }

    @objc private func toggleMinimalMenuBarMode() {
        StatsManager.shared.minimalMenuBarMode = (minimalMenuBarModeButton.state == .on)
        updateMenuBarPreview()
        updateDynamicIconColorStyleSelection()
    }

    @objc private func toggleAppStatsEnabled() {
        StatsManager.shared.appStatsEnabled = (appStatsEnabledButton.state == .on)
    }

    @objc private func toggleDynamicIconColor() {
        StatsManager.shared.enableDynamicIconColor = dynamicIconColorButton.state == .on
        updateDynamicIconColorStyleSelection()
    }

    @objc private func dynamicIconColorStyleChanged() {
        if StatsManager.shared.minimalMenuBarMode {
            UserDefaults.standard.set(DynamicIconColorStyle.dot.rawValue, forKey: dynamicIconColorStyleKey)
            updateDynamicIconColorStyleSelection()
            StatsManager.shared.menuBarUpdateHandler?()
            return
        }
        guard let rawValue = dynamicIconColorStylePopUp.selectedItem?.representedObject as? String else { return }
        UserDefaults.standard.set(rawValue, forKey: dynamicIconColorStyleKey)
        StatsManager.shared.menuBarUpdateHandler?()
    }

    @objc private func toggleLaunchAtLogin() {
        let shouldEnable = launchAtLoginButton.state == .on
        do {
            try LaunchAtLoginManager.shared.setEnabled(shouldEnable)
            updateState()
            AppDelegate.trackClick("setting_launch_at_login", properties: ["enabled": shouldEnable])
        } catch {
            updateState()
            showLaunchAtLoginError()
        }
    }

    @objc private func calibrateMouseDistance() {
        AppDelegate.trackClick("open_mouse_calibration")
        MouseDistanceCalibrationWindowController.shared.show()
    }

    @objc private func openGitHubRepository() {
        guard let url = githubRepositoryURL else { return }
        AppDelegate.trackClick("open_github_repository")
        NSWorkspace.shared.open(url)
    }

    @objc private func resetStats() {
        let alert = NSAlert()
        let appIcon = NSApp.applicationIconImage
        alert.icon = appIcon
        alert.messageText = NSLocalizedString("stats.reset.title", comment: "")
        alert.informativeText = NSLocalizedString("stats.reset.message", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("stats.reset.confirm", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("stats.reset.cancel", comment: ""))

        if alert.runModal() == .alertFirstButtonReturn {
            StatsManager.shared.resetStats()
            AppDelegate.trackEvent("stats_reset")
        }
    }

    @objc private func exportData() {
        AppDelegate.trackClick("export_data")
        let savePanel = NSSavePanel()
        savePanel.allowedFileTypes = ["json"]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = makeExportFileName()
        savePanel.title = NSLocalizedString("export.savePanel.title", comment: "")
        savePanel.message = NSLocalizedString("export.savePanel.message", comment: "")
        savePanel.prompt = NSLocalizedString("export.savePanel.prompt", comment: "")

        guard let window = view.window else {
            if savePanel.runModal() == .OK, let url = savePanel.url {
                writeExport(to: url)
            }
            return
        }

        savePanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = savePanel.url else { return }
            self?.writeExport(to: url)
        }
    }

    @objc private func importData() {

        AppDelegate.trackClick("import_data")
        let openPanel = NSOpenPanel()
        openPanel.allowedFileTypes = ["json"]
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.title = NSLocalizedString("import.openPanel.title", comment: "")
        openPanel.message = NSLocalizedString("import.openPanel.message", comment: "")
        openPanel.prompt = NSLocalizedString("import.openPanel.prompt", comment: "")

        guard let window = view.window else {
            if openPanel.runModal() == .OK, let url = openPanel.url {
                confirmAndImport(from: url)
            }
            return
        }

        openPanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = openPanel.url else { return }
            self?.confirmAndImport(from: url)
        }
    }

    private func makeExportFileName() -> String {
        let dateString = exportFileDateFormatter.string(from: Date())
        return "Keytide-Export-\(dateString).json"
    }

    private func writeExport(to url: URL) {
        do {
            let data = try StatsManager.shared.exportStatsData()
            try data.write(to: url, options: .atomic)
        } catch {
            showExportError(error)
        }
    }

    private func confirmAndImport(from url: URL) {
        let alert = NSAlert()
        let appIcon = NSApp.applicationIconImage
        alert.icon = appIcon
        alert.messageText = NSLocalizedString("import.confirm.title", comment: "")
        alert.informativeText = NSLocalizedString("import.confirm.message", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("import.confirm.overwrite", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("import.confirm.merge", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("import.confirm.cancel", comment: ""))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            confirmModeAndImport(from: url, mode: .overwrite)
        case .alertSecondButtonReturn:
            confirmModeAndImport(from: url, mode: .merge)
        default:
            break
        }
    }

    private func confirmModeAndImport(from url: URL, mode: StatsManager.ImportMode) {
        let alert = NSAlert()
        let appIcon = NSApp.applicationIconImage
        alert.icon = appIcon
        alert.messageText = NSLocalizedString("import.confirm.mode.title", comment: "")
        alert.alertStyle = .warning
        alert.accessoryView = makeModeConfirmationTextView(mode: mode)
        alert.addButton(withTitle: NSLocalizedString("import.confirm.mode.confirm", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("import.confirm.cancel", comment: ""))

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performImport(from: url, mode: mode)
    }

    private func makeModeConfirmationTextView(mode: StatsManager.ImportMode) -> NSView {
        let messageKey = mode == .overwrite
            ? "import.confirm.mode.message.overwrite"
            : "import.confirm.mode.message.merge"
        let keywordKey = mode == .overwrite
            ? "import.confirm.mode.keyword.overwrite"
            : "import.confirm.mode.keyword.merge"

        let message = NSLocalizedString(messageKey, comment: "")
        let keyword = NSLocalizedString(keywordKey, comment: "")
        let regularFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let boldFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        let attributed = NSMutableAttributedString(
            string: message,
            attributes: [.font: regularFont, .foregroundColor: NSColor.labelColor]
        )

        if let range = message.range(of: keyword) {
            attributed.addAttribute(.font, value: boldFont, range: NSRange(range, in: message))
        }

        let label = NSTextField(labelWithAttributedString: attributed)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 320

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 44))
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    private func performImport(from url: URL, mode: StatsManager.ImportMode) {
        do {
            let data = try Data(contentsOf: url)
            try StatsManager.shared.importStatsData(from: data, mode: mode)
            AppDelegate.trackEvent("stats_imported", properties: ["mode": mode == .overwrite ? "overwrite" : "merge"])
            showImportSuccess(mode: mode)
        } catch {
            showImportError(error)
        }
    }

    private func showImportSuccess(mode: StatsManager.ImportMode) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "import.success.title",
            tableName: nil,
            bundle: .main,
            value: "Import Complete",
            comment: ""
        )
        alert.informativeText = NSLocalizedString(
            mode == .overwrite ? "import.success.message.overwrite" : "import.success.message.merge",
            tableName: nil,
            bundle: .main,
            value: mode == .overwrite
                ? "Statistics data has been imported and replaced successfully."
                : "Statistics data has been imported and merged successfully.",
            comment: ""
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("button.ok", comment: ""))
        alert.runModal()
    }

    private func showExportError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("export.error.title", comment: "")
        alert.informativeText = String(format: NSLocalizedString("export.error.message", comment: ""), error.localizedDescription)
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("button.ok", comment: ""))
        alert.runModal()
    }

    private func showImportError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("import.error.title", comment: "")
        alert.informativeText = String(format: NSLocalizedString("import.error.message", comment: ""), error.localizedDescription)
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("button.ok", comment: ""))
        alert.runModal()
    }

    private func showLaunchAtLoginError() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("launchAtLogin.error.title", comment: "")
        alert.informativeText = NSLocalizedString("launchAtLogin.error.message", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("button.ok", comment: ""))
        alert.runModal()
    }
}
