import Cocoa
private func resolvedCGColor(_ color: NSColor, for view: NSView) -> CGColor {
    var resolved: CGColor = color.cgColor
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        resolved = color.cgColor
    }
    return resolved
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
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}

    override var isSelected: Bool {
        didSet { updateContents() }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        updateContents()
    }

    private func updateContents() {
        for case let cell as NSTableCellView in subviews {
            cell.textField?.font = .systemFont(ofSize: 13, weight: isSelected ? .semibold : .medium)
            cell.textField?.textColor = isSelected ? .labelColor : .secondaryLabelColor
            cell.imageView?.contentTintColor = isSelected ? .controlAccentColor : .secondaryLabelColor
        }
    }
}

/// The table owns selection and hit testing. A single layer behind it follows the selected row.
private final class SettingsNavigationView: NSView {
    let table = NSTableView()
    private let backdrop = NSView()
    private let selection = CALayer()
    private var colorObserver: NSObjectProtocol?
    private var displayObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        backdrop.wantsLayer = true
        selection.cornerRadius = 9
        selection.cornerCurve = .continuous
        selection.borderWidth = 1
        selection.isHidden = true
        backdrop.layer?.addSublayer(selection)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.documentView = table
        for child in [backdrop, scroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: leadingAnchor),
                child.trailingAnchor.constraint(equalTo: trailingAnchor),
                child.topAnchor.constraint(equalTo: topAnchor),
                child.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        colorObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateColors() }
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateColors()
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { self?.finishSelectionAnimation() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let colorObserver { NotificationCenter.default.removeObserver(colorObserver) }
        if let displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayObserver) }
    }

    override func layout() {
        super.layout()
        updateSelection(animated: false)
    }

    func updateColors() {
        let strong = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selection.backgroundColor = resolvedCGColor(.controlAccentColor, alpha: strong ? 0.28 : 0.17, for: self)
        selection.borderColor = resolvedCGColor(.controlAccentColor, alpha: strong ? 0.65 : 0.30, for: self)
        CATransaction.commit()
    }

    func updateSelection(animated: Bool) {
        guard table.selectedRow >= 0 else {
            selection.removeAllAnimations()
            selection.isHidden = true
            return
        }
        let row = backdrop.convert(table.rect(ofRow: table.selectedRow), from: table)
        let target = NSRect(x: 1, y: row.minY + 2, width: backdrop.bounds.width - 2, height: row.height - 4)
        guard !target.isEmpty, selection.isHidden || selection.frame != target else { return }

        let from = selection.presentation()?.position ?? selection.position
        let shouldAnimate = animated && !selection.isHidden && window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selection.removeAnimation(forKey: "position")
        selection.frame = target
        selection.isHidden = false
        CATransaction.commit()

        if shouldAnimate {
            let slide = CABasicAnimation(keyPath: "position")
            slide.fromValue = NSValue(point: from)
            slide.toValue = NSValue(point: selection.position)
            slide.duration = 0.22
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.75, 0.25, 1)
            selection.add(slide, forKey: "position")
        }
    }

    func finishSelectionAnimation() {
        selection.removeAnimation(forKey: "position")
    }
}

final class SettingsViewController: NSViewController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private let navigationView = SettingsNavigationView()
    private var navigation: NSTableView { navigationView.table }
    private var pages: [[NSView]] = []
    private let pageKeys = ["general", "appearance", "notifications", "data"]
    private let pageSymbols = ["gearshape", "menubar.rectangle", "bell", "externaldrive"]
    private(set) var selectedPage = 0
    private var displayedPage: Int?

    private var scrollView: NSScrollView!
    private var documentView: NSView!
    private var contentStack: NSStackView!

    private var headerTitleLabel: NSTextField!
    private var headerSubtitleLabel: NSTextField!
    private var githubButton: NSButton!

    private var menuBarNumbersPopUp: NSPopUpButton!
    private var menuBarPreview: MenuBarStatusView!
    private var menuBarPreviewWidth: NSLayoutConstraint!
    private var menuUIStylePopUp: NSPopUpButton!
    private var appStatsEnabledButton: NSSwitch!
    private var replayRecordingButton: NSSwitch!
    private var replayStatusLabel: NSTextField!
    private var replayObserver: NSObjectProtocol?
    private var trackpadRecordingButton: NSSwitch!
    private var trackpadRecordingStatus: NSTextField!
    private var deleteTrackpadButton: NSButton!
    private var trackpadObserver: NSObjectProtocol?
    private var launchAtLoginButton: NSSwitch!
    private var backgroundInputButton: NSSwitch!
    private var backgroundInputStatus: NSTextField!
    private var backgroundInputObserver: NSObjectProtocol?
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
    private var notificationThresholdContainer: NSStackView!

    private var cardViews: [NSView] = []
    private var optionDividerViews: [NSView] = []
    private let fileTransferQueue = DispatchQueue(label: "Keytide.SettingsFileTransfers", qos: .userInitiated)
    private(set) var fileTransferInProgress = false
    private var appearanceObservation: NSKeyValueObservation?

    func restorePage(_ page: Int) { selectedPage = page }
    private var systemThemeObserver: NSObjectProtocol?
    private var appDidBecomeActiveObserver: NSObjectProtocol?

    private let thresholdMinimum = 0
    private let thresholdMaximum = 1_000_000
    private let thresholdStep = 100.0
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
        replayObserver = NotificationCenter.default.addObserver(forName: .keyReplayRecordingChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateReplayState()
        }
        trackpadObserver = NotificationCenter.default.addObserver(forName: TrackpadAppService.didChange,
            object: TrackpadAppService.shared, queue: .main) { [weak self] _ in self?.updateTrackpadRecordingState() }
        backgroundInputObserver = NotificationCenter.default.addObserver(forName: BackgroundInputController.didChange,
            object: nil, queue: .main) { [weak self] _ in self?.updateBackgroundInputState() }
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
        updateReplayState()
        updateState()
        updateAppearance()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(navigation)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        navigationView.finishSelectionAnimation()
    }

    deinit {
        if let backgroundInputObserver { NotificationCenter.default.removeObserver(backgroundInputObserver) }
        if let replayObserver { NotificationCenter.default.removeObserver(replayObserver) }
        if let trackpadObserver { NotificationCenter.default.removeObserver(trackpadObserver) }
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
        // AppKit can select the first row while reloading the navigation table.
        let initialPage = selectedPage
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebar)
        let sidebarStack = NSStackView()
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 24
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarStack)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        documentView = SettingsDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 22
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)

        let appIconView = NSImageView(image: NSApp.applicationIconImage)
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.setAccessibilityElement(false)
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        appIconView.widthAnchor.constraint(equalToConstant: 36).isActive = true
        appIconView.heightAnchor.constraint(equalToConstant: 36).isActive = true

        headerTitleLabel = NSTextField(labelWithString: NSLocalizedString("settings.windowTitle", comment: ""))
        headerTitleLabel.font = NSFont.systemFont(ofSize: 29, weight: .semibold)

        headerSubtitleLabel = NSTextField(wrappingLabelWithString: "")
        headerSubtitleLabel.font = NSFont.systemFont(ofSize: 13)
        headerSubtitleLabel.textColor = .secondaryLabelColor

        let versionString: String = {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
            return "v\(version) (\(build))"
        }()
        let versionLabel = NSTextField(labelWithString: versionString)
        versionLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor

        githubButton = makeSymbolButton(
            systemName: "chevron.left.forwardslash.chevron.right",
            fallbackTitle: NSLocalizedString("settings.github", comment: ""),
            pointSize: 13,
            weight: .semibold,
            action: #selector(openGitHubRepository)
        )
        githubButton.toolTip = NSLocalizedString("settings.github.tooltip", comment: "")
        githubButton.setAccessibilityLabel(NSLocalizedString("settings.github", comment: ""))
        githubButton.imageScaling = .scaleProportionallyDown
        if let hoverButton = githubButton as? HoverIconButton {
            hoverButton.padding = 5
            hoverButton.cornerRadius = 7
        }
        NSLayoutConstraint.activate([
            githubButton.widthAnchor.constraint(equalToConstant: 28),
            githubButton.heightAnchor.constraint(equalToConstant: 28)
        ])
        applyBundledGitHubIconIfNeeded()

        let brand = NSTextField(labelWithString: "Keytide")
        brand.font = .systemFont(ofSize: 17, weight: .semibold)
        let identity = NSStackView(views: [appIconView, brand])
        identity.orientation = .horizontal
        identity.spacing = 10
        identity.alignment = .centerY
        sidebarStack.addArrangedSubview(identity)
        let sidebarWidth: CGFloat = 198
        let sidebarInset: CGFloat = 14
        let rowHeight: CGFloat = 40
        let rowSpacing: CGFloat = 4
        let navigationHeight = CGFloat(pageKeys.count) * (rowHeight + rowSpacing)
        navigation.frame = NSRect(x: 0, y: 0, width: sidebarWidth - 2 * sidebarInset, height: navigationHeight)
        navigation.autoresizingMask = [.width]
        navigation.headerView = nil
        navigation.style = .plain
        navigation.backgroundColor = .clear
        navigation.rowHeight = rowHeight
        navigation.intercellSpacing = NSSize(width: 0, height: rowSpacing)
        navigation.selectionHighlightStyle = .regular
        navigation.allowsEmptySelection = false
        navigation.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        navigation.setAccessibilityLabel(NSLocalizedString("settings.windowTitle", comment: ""))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("category"))
        column.resizingMask = .autoresizingMask
        column.width = navigation.frame.width
        navigation.addTableColumn(column)
        navigation.dataSource = self
        navigation.delegate = self
        addArrangedSubviewFillingWidth(navigationView, to: sidebarStack)
        navigationView.heightAnchor.constraint(equalToConstant: navigationHeight).isActive = true

        let privacyLabel = NSTextField(wrappingLabelWithString: NSLocalizedString("settings.localOnly", comment: ""))
        privacyLabel.font = .systemFont(ofSize: 11)
        privacyLabel.textColor = .secondaryLabelColor
        let footerRow = NSStackView(views: [versionLabel, NSView(), githubButton])
        footerRow.alignment = .centerY
        let footer = makeVerticalStack(spacing: 6)
        addArrangedSubviewFillingWidth(StatsWindowStyle.separator(), to: footer)
        addArrangedSubviewFillingWidth(privacyLabel, to: footer)
        addArrangedSubviewFillingWidth(footerRow, to: footer)
        sidebar.addSubview(footer)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: sidebarInset),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -sidebarInset),
            sidebarStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            footer.leadingAnchor.constraint(equalTo: sidebarStack.leadingAnchor, constant: 3),
            footer.trailingAnchor.constraint(equalTo: sidebarStack.trailingAnchor, constant: -3),
            footer.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16),
            footer.topAnchor.constraint(greaterThanOrEqualTo: sidebarStack.bottomAnchor, constant: 16)
        ])

        let header = makeVerticalStack(spacing: 5)
        header.addArrangedSubview(headerTitleLabel)
        addArrangedSubviewFillingWidth(headerSubtitleLabel, to: header)
        view.addSubview(header)
        let headerDivider = StatsWindowStyle.separator()
        view.addSubview(headerDivider)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 19),
            header.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 30),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -30),
            headerDivider.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            headerDivider.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerDivider.bottomAnchor)
        ])

        appStatsEnabledButton = makeSwitch(action: #selector(toggleAppStatsEnabled))
        launchAtLoginButton = makeSwitch(action: #selector(toggleLaunchAtLogin))
        backgroundInputButton = makeSwitch(action: #selector(toggleBackgroundInput))
        showThresholdsButton = makeSwitch(action: #selector(toggleShowThresholds))
        menuUIStylePopUp = NSPopUpButton()
        menuUIStylePopUp.addItems(withTitles: [
            NSLocalizedString("settings.uiStyle.standard", comment: ""),
            NSLocalizedString("settings.uiStyle.geek", comment: "")
        ])
        menuUIStylePopUp.target = self
        menuUIStylePopUp.action = #selector(changeMenuUIStyle)
        menuUIStylePopUp.setAccessibilityLabel(NSLocalizedString("settings.uiStyle", comment: ""))
        menuBarNumbersPopUp = NSPopUpButton()
        menuBarNumbersPopUp.addItems(withTitles: [NSLocalizedString("settings.menuDisplay.compact", comment: ""), NSLocalizedString("settings.menuDisplay.full", comment: "")])
        menuBarNumbersPopUp.target = self
        menuBarNumbersPopUp.action = #selector(changeMenuBarDisplay)
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
            makeLabeledRow(title: NSLocalizedString("settings.menuDisplay.numbers", comment: ""), control: menuBarNumbersPopUp),
            makeLabeledRow(title: NSLocalizedString("settings.menuDisplay.preview", comment: ""), control: menuBarPreview)
        ])

        let menuBarSection = makeSection(titleKey: "settings.section.menuBar", content: menuBarStack)

        let trackingStack = makeVerticalStack(spacing: 8)
        let appStatsRow = makeSwitchRow(titleKey: "setting.appStatsEnabled", toggle: appStatsEnabledButton)
        let launchRow = makeSwitchRow(titleKey: "button.launchAtLogin", toggle: launchAtLoginButton)
        addArrangedSubviewFillingWidth(appStatsRow, to: trackingStack)
        addArrangedSubviewFillingWidth(makeOptionDividerContainer(), to: trackingStack)
        addArrangedSubviewFillingWidth(launchRow, to: trackingStack)
        let loginHelp = NSTextField(wrappingLabelWithString: NSLocalizedString("settings.appLogin.help", comment: ""))
        loginHelp.font = .systemFont(ofSize: 11)
        loginHelp.textColor = .secondaryLabelColor
        addArrangedSubviewFillingWidth(loginHelp, to: trackingStack)
        addArrangedSubviewFillingWidth(makeOptionDividerContainer(), to: trackingStack)
        let backgroundRow = makeSwitchRow(titleKey: "backgroundInput.title", toggle: backgroundInputButton)
        addArrangedSubviewFillingWidth(backgroundRow, to: trackingStack)
        let backgroundHelp = NSTextField(wrappingLabelWithString: NSLocalizedString("backgroundInput.help", comment: ""))
        backgroundHelp.font = .systemFont(ofSize: 11)
        backgroundHelp.textColor = .secondaryLabelColor
        addArrangedSubviewFillingWidth(backgroundHelp, to: trackingStack)
        backgroundInputStatus = NSTextField(wrappingLabelWithString: "")
        backgroundInputStatus.font = .systemFont(ofSize: 11)
        backgroundInputStatus.textColor = .secondaryLabelColor
        addArrangedSubviewFillingWidth(backgroundInputStatus, to: trackingStack)
        addArrangedSubviewFillingWidth(makeOptionDividerContainer(), to: trackingStack)
        let welcomeButton = NSButton(title: NSLocalizedString("welcome.reopen", comment: ""), target: self, action: #selector(reopenWelcome))
        welcomeButton.bezelStyle = .rounded
        trackingStack.addArrangedSubview(welcomeButton)

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

        let notificationSection = makeSection(content: notificationStack)

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
        addArrangedSubviewFillingWidth(makeActionRow("settings.data.calibration", help: "settings.data.calibrationHelp", control: mouseDistanceCalibrationButton), to: actionStack)
        addArrangedSubviewFillingWidth(makeOptionDividerContainer(), to: actionStack)
        let transferButtons = NSStackView(views: [importButton, exportButton])
        transferButtons.spacing = 8
        addArrangedSubviewFillingWidth(makeActionRow("settings.data.transfer", help: "settings.data.transferHelp", control: transferButtons), to: actionStack)
        let resetSection = makeSection(content: makeActionRow("settings.data.reset", help: "settings.data.resetHelp", control: resetButton))
        resetButton.contentTintColor = .systemRed

        let actionSection = makeSection(content: actionStack)

        replayRecordingButton = makeSwitch(action: #selector(toggleReplayRecording))
        replayStatusLabel = NSTextField(wrappingLabelWithString: "")
        replayStatusLabel.font = .systemFont(ofSize: 11); replayStatusLabel.textColor = .secondaryLabelColor
        let replayHelp = NSTextField(wrappingLabelWithString: NSLocalizedString("replay.recording.help", comment: ""))
        replayHelp.font = .systemFont(ofSize: 11); replayHelp.textColor = .secondaryLabelColor
        let replayOptions = makeVerticalStack(spacing: 10)
        for child in [makeSwitchRow(titleKey: "replay.recording.enable", toggle: replayRecordingButton), replayHelp, replayStatusLabel!] {
            addArrangedSubviewFillingWidth(child, to: replayOptions)
        }
        let deleteReplay = NSButton(title: NSLocalizedString("replay.recording.delete", comment: ""), target: self, action: #selector(deleteReplayRecords))
        deleteReplay.bezelStyle = .rounded
        replayOptions.addArrangedSubview(deleteReplay)
        let replaySection = makeSection(titleKey: "replay.recording.title", content: replayOptions)
        updateReplayState()
        trackpadRecordingButton = makeSwitch(action: #selector(toggleTrackpadRecording))
        trackpadRecordingStatus = NSTextField(wrappingLabelWithString: "")
        let trackpadHelp = NSTextField(wrappingLabelWithString: NSLocalizedString("trackpad.record.help", comment: ""))
        let trackpadOptions = makeVerticalStack(spacing: 10)
        addArrangedSubviewFillingWidth(makeSwitchRow(titleKey: "trackpad.record.always", toggle: trackpadRecordingButton), to: trackpadOptions)
        for label in [trackpadHelp, trackpadRecordingStatus!] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            addArrangedSubviewFillingWidth(label, to: trackpadOptions)
        }
        deleteTrackpadButton = NSButton(title: NSLocalizedString("trackpad.delete", comment: ""), target: self, action: #selector(deleteTrackpadRecords))
        deleteTrackpadButton.bezelStyle = .rounded
        trackpadOptions.addArrangedSubview(deleteTrackpadButton)
        let trackpadSection = makeSection(titleKey: "trackpad.title", content: trackpadOptions)
        updateTrackpadRecordingState()
        pages = [[trackingSection], [menuBarSection], [notificationSection],
                 [actionSection, replaySection, trackpadSection, resetSection]]

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 30),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -30),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24)
        ])
        navigation.reloadData()
        navigation.selectRowIndexes(IndexSet(integer: initialPage), byExtendingSelection: false)
        showPage(initialPage)
    }

    private func updateReplayState() {
        replayRecordingButton?.state = KeyReplayRecording.shared.isEnabled ? .on : .off
        replayRecordingButton?.isEnabled = !KeyReplayRecording.shared.changing
        replayStatusLabel?.stringValue = NSLocalizedString(KeyReplayRecording.shared.statusKey, comment: "")
    }

    private func updateTrackpadRecordingState() {
        let service = TrackpadAppService.shared
        trackpadRecordingButton?.state = service.recording ? .on : .off
        trackpadRecordingButton?.isEnabled = service.canChangeRecording
        deleteTrackpadButton?.isEnabled = service.canChangeRecording
        trackpadRecordingStatus?.stringValue = NSLocalizedString(service.recordingStatusKey, comment: "")
    }

    @objc private func toggleTrackpadRecording() {
        let enable = trackpadRecordingButton.state == .on
        if enable {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("trackpad.record", comment: "")
            alert.informativeText = NSLocalizedString("trackpad.consent", comment: "")
            alert.addButton(withTitle: NSLocalizedString("replay.consent.enable", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("button.cancel", comment: ""))
            guard alert.runModal() == .alertFirstButtonReturn else { updateTrackpadRecordingState(); return }
        }
        TrackpadAppService.shared.setRecording(enable) { [weak self] _ in
            self?.updateTrackpadRecordingState()
        }
    }

    @objc private func deleteTrackpadRecords() {
        guard TrackpadAppService.shared.canChangeRecording else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("trackpad.delete.confirm", comment: "")
        alert.informativeText = NSLocalizedString("trackpad.delete.help", comment: "")
        alert.addButton(withTitle: NSLocalizedString("trackpad.delete", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("button.cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        TrackpadAppService.shared.deleteAll { ok in
            guard !ok else { return }
            let failure = NSAlert()
            failure.messageText = NSLocalizedString("replay.delete.failed", comment: "")
            failure.runModal()
        }
    }

    @objc private func toggleReplayRecording() {
        if replayRecordingButton.state == .on {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("replay.consent.title", comment: "")
            alert.informativeText = NSLocalizedString("replay.consent.body", comment: "")
            alert.addButton(withTitle: NSLocalizedString("replay.consent.enable", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("button.cancel", comment: ""))
            guard alert.runModal() == .alertFirstButtonReturn else { updateReplayState(); return }
        }
        KeyReplayRecording.shared.setEnabled(replayRecordingButton.state == .on)
        updateReplayState()
    }

    @objc private func deleteReplayRecords() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("replay.delete.title", comment: "")
        alert.informativeText = NSLocalizedString("replay.delete.body", comment: "")
        alert.addButton(withTitle: NSLocalizedString("replay.recording.delete", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("button.cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        KeyReplayRecording.shared.deleteAll { [weak self] ok in
            self?.updateReplayState()
            if !ok { let failure = NSAlert(); failure.messageText = NSLocalizedString("replay.delete.failed", comment: ""); failure.runModal() }
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SettingsNavigationRow()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { pageKeys.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: NSLocalizedString("settings.navigation." + pageKeys[row], comment: ""))
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: pageSymbols[row], accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        label.lineBreakMode = .byTruncatingTail
        for child in [icon, label] { child.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(child) }
        cell.textField = label; cell.imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 13),
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard navigation.selectedRow >= 0 else { return }
        navigationView.updateSelection(animated: true)
        showPage(navigation.selectedRow)
    }

    private func showPage(_ index: Int) {
        guard pages.indices.contains(index), displayedPage != index else { return }
        selectedPage = index
        displayedPage = index
        for child in contentStack.arrangedSubviews { child.removeFromSuperview() }
        headerTitleLabel.stringValue = NSLocalizedString("settings.page." + pageKeys[index], comment: "")
        headerSubtitleLabel.stringValue = NSLocalizedString("settings.page." + pageKeys[index] + ".help", comment: "")
        for section in pages[index] { addArrangedSubviewFillingWidth(section, to: contentStack) }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func makeActionRow(_ title: String, help: String, control: NSView) -> NSView {
        let text = NSTextField(wrappingLabelWithString: NSLocalizedString(title, comment: ""))
        text.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(wrappingLabelWithString: NSLocalizedString(help, comment: ""))
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [text, detail])
        labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 4
        return makeLabeledRowView(labels: labels, control: control)
    }

    private func makeLabeledRowView(labels: NSView, control: NSView) -> NSView {
        let row = NSStackView(views: [labels, NSView(), control])
        row.orientation = .horizontal; row.spacing = 16; row.alignment = .centerY
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }

    private func makeSection(titleKey: String? = nil, content: NSView) -> NSView {
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
        guard let titleKey else { return card }

        let titleLabel = makeSectionTitleLabel(NSLocalizedString(titleKey, comment: ""))
        let wrapper = makeVerticalStack(spacing: 8)
        wrapper.addArrangedSubview(titleLabel)
        addArrangedSubviewFillingWidth(card, to: wrapper)

        return wrapper
    }

    private func makeSectionTitleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        return label
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
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = resolvedCGColor(.windowBackgroundColor, for: view)
        view.window?.backgroundColor = .windowBackgroundColor
        navigationView.updateColors()
        let cardColor: NSColor
        if #available(macOS 14.0, *) {
            cardColor = .quaternarySystemFill
        } else {
            cardColor = .labelColor.withAlphaComponent(0.055)
        }

        for card in cardViews {
            card.layer?.cornerRadius = 14
            card.layer?.cornerCurve = .continuous
            card.layer?.backgroundColor = resolvedCGColor(cardColor, for: view)
        }

        for divider in optionDividerViews {
            divider.layer?.backgroundColor = resolvedCGColor(.separatorColor, for: view)
        }
    }

    // MARK: - State

    @objc private func changeMenuUIStyle() {
        let style = MenuUIStyle.allCases[menuUIStylePopUp.indexOfSelectedItem]
        UserDefaults.standard.set(style.rawValue, forKey: MenuUIStyle.defaultsKey)
        NotificationCenter.default.post(name: .menuUIStyleDidChange, object: nil)
    }

    @objc private func changeMenuBarDisplay() {
        UserDefaults.standard.set(menuBarNumbersPopUp.indexOfSelectedItem == 1, forKey: MenuBarDisplayPreferences.fullNumbersKey)
        updateMenuBarPreview()
        StatsManager.shared.menuBarUpdateHandler?()
    }

    private func updateMenuBarPreview() {
        let full = UserDefaults.standard.bool(forKey: MenuBarDisplayPreferences.fullNumbersKey)
        menuBarNumbersPopUp.selectItem(at: full ? 1 : 0)
        menuBarPreview.update(.init(
            keysText: MenuBarDisplayPreferences.number(12856, full: full),
            clicksText: MenuBarDisplayPreferences.number(3210, full: full),
            fullNumbers: full
        ))
        menuBarPreviewWidth.constant = menuBarPreview.intrinsicContentSize.width
    }

    private func updateState() {
        updateMenuBarPreview()
        menuUIStylePopUp.selectItem(at: MenuUIStyle.allCases.firstIndex(of: MenuUIStyle.current) ?? 0)
        appStatsEnabledButton.state = StatsManager.shared.appStatsEnabled ? .on : .off
        launchAtLoginButton.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off
        updateBackgroundInputState()
        let notificationsEnabled = StatsManager.shared.notificationsEnabled
        showThresholdsButton.state = notificationsEnabled ? .on : .off
        notificationThresholdContainer.isHidden = !notificationsEnabled
        updateThresholdUI()
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
        BackgroundInputController.shared.updateThresholdPreferences()
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
        thresholdFieldEdited(field)
    }

    // MARK: - Actions

    @objc private func toggleShowThresholds() {
        let enabled = showThresholdsButton.state == .on
        StatsManager.shared.notificationsEnabled = enabled
        notificationThresholdContainer.isHidden = !enabled
        BackgroundInputController.shared.updateThresholdPreferences()
        if enabled {
            requestNotificationPermissionIfNeeded()
        }
    }

    @objc private func toggleAppStatsEnabled() {
        let enabled = appStatsEnabledButton.state == .on
        StatsManager.shared.appStatsEnabled = enabled
        BackgroundInputController.shared.updateAttribution(enabled)
    }

    private func updateBackgroundInputState() {
        let controller = BackgroundInputController.shared
        backgroundInputButton?.state = controller.isEnabled ? .on : .off
        let message = controller.statusMessage
        backgroundInputStatus?.stringValue = message.map { NSLocalizedString($0, comment: "") } ?? ""
        backgroundInputStatus?.isHidden = message == nil
    }

    @objc private func toggleBackgroundInput() {
        BackgroundInputController.shared.setAllowed(backgroundInputButton.state == .on)
    }

    private func showHelperRequestError() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("backgroundInput.error", comment: "")
        alert.runModal()
    }

    @objc private func reopenWelcome() { AppDelegate.shared?.showOnboarding(restart: true) }

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
            BackgroundInputController.shared.request(.resetStats) { [weak self] _, ok in
                if ok { AppDelegate.trackEvent("stats_reset") }
                else { self?.showHelperRequestError() }
            }
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
        guard !fileTransferInProgress else { return }
        setFileTransferInProgress(true, importing: false)
        let snapshot = StatsManager.shared.exportSnapshot()
        fileTransferQueue.async { [weak self] in
            let result = Result { try snapshot.encodedData().write(to: url, options: .atomic) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.setFileTransferInProgress(false)
                if case .failure(let error) = result { self.showExportError(error) }
            }
        }
    }

    private func setFileTransferInProgress(_ inProgress: Bool, importing: Bool = false) {
        fileTransferInProgress = inProgress
        for button in [importButton, exportButton, resetButton] { button?.isEnabled = !inProgress }
        importButton.title = NSLocalizedString(inProgress && importing ? "import.inProgress" : "button.importData", comment: "")
        exportButton.title = NSLocalizedString(inProgress && !importing ? "export.inProgress" : "button.exportData", comment: "")
        if !inProgress {
            DispatchQueue.main.async { SettingsWindowController.shared.releaseClosedWindow() }
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
        guard !fileTransferInProgress else { return }
        setFileTransferInProgress(true, importing: true)
        fileTransferQueue.async { [weak self] in
            let result = Result {
                let raw = try Data(contentsOf: url)
                _ = try StatsManager.prepareStatsImport(from: raw)
                return raw
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let raw):
                    let command: InputControl = mode == .overwrite ? .overwriteStats : .mergeStats
                    BackgroundInputController.shared.request(command, data: raw) { [weak self] _, ok in
                        guard let self else { return }
                        self.setFileTransferInProgress(false)
                        guard ok else { self.showHelperRequestError(); return }
                        AppDelegate.trackEvent("stats_imported", properties: ["mode": mode == .overwrite ? "overwrite" : "merge"])
                        self.showImportSuccess(mode: mode)
                    }
                case .failure(let error):
                    self.setFileTransferInProgress(false)
                    self.showImportError(error)
                }
            }
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
