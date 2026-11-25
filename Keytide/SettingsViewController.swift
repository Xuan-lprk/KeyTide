import SwiftUI
import UniformTypeIdentifiers

/// Hosts the SwiftUI settings and connects its actions to the app's existing services.
final class SettingsViewController: NSHostingController<SettingsView> {
    private let model: SettingsModel
    private var observers: [NSObjectProtocol] = []
    private let fileTransferQueue = DispatchQueue(label: "Keytide.SettingsFileTransfers", qos: .userInitiated)

    var selectedPage: SettingsPage { model.page }
    var fileTransferInProgress: Bool { model.values.transfer != nil }

    func selectPage(_ page: SettingsPage) { model.selectPage(page) }

    init(page: SettingsPage) {
        let model = SettingsModel(page: page)
        self.model = model
        super.init(rootView: SettingsView(model: model))
        // The window supplies its own minimum size and the content pane scrolls.
        sizingOptions = []
        model.send = { [weak self] action in self?.perform(action) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .keyReplayRecordingChanged, object: nil, queue: .main) { [weak self] _ in
                self?.refreshReplay()
            },
            center.addObserver(forName: TrackpadAppService.didChange, object: TrackpadAppService.shared, queue: .main) { [weak self] _ in
                self?.refreshTrackpad()
            },
            center.addObserver(forName: BackgroundInputController.didChange, object: nil, queue: .main) { [weak self] _ in
                self?.refreshBackgroundInput()
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.model.values.launchAtLogin = LaunchAtLoginManager.shared.isEnabled
            }
        ]
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func refresh() {
        let stats = StatsManager.shared
        model.values.trackApps = stats.appStatsEnabled
        model.values.launchAtLogin = LaunchAtLoginManager.shared.isEnabled
        model.values.menuPresentation = MenuPresentation.load()
        model.values.menuWidgets = MenuWidgetPreferences.load()
        model.values.fullNumbers = UserDefaults.standard.bool(forKey: MenuBarDisplayPreferences.fullNumbersKey)
        model.values.notifications = stats.notificationsEnabled
        model.keyThreshold = String(stats.keyPressNotifyThreshold)
        model.clickThreshold = String(stats.clickNotifyThreshold)
        refreshBackgroundInput()
        refreshReplay()
        refreshTrackpad()
    }

    private func refreshBackgroundInput() {
        let controller = BackgroundInputController.shared
        model.values.backgroundInput = controller.isEnabled
        model.values.backgroundStatus = controller.statusMessage
    }

    private func refreshReplay() {
        let service = KeyReplayRecording.shared
        model.values.replay = service.isEnabled
        model.values.replayAvailable = !service.changing
        model.values.replayStatus = service.statusKey
    }

    private func refreshTrackpad() {
        let service = TrackpadAppService.shared
        model.values.trackpad = service.recording
        model.values.trackpadAvailable = service.canChangeRecording
        model.values.trackpadStatus = service.recordingStatusKey
    }

    private func perform(_ action: SettingsAction) {
        switch action {
        case .trackApps(let enabled):
            StatsManager.shared.appStatsEnabled = enabled
            model.values.trackApps = enabled
            BackgroundInputController.shared.updateAttribution(enabled)
        case .launchAtLogin(let enabled):
            toggleLaunchAtLogin(enabled)
        case .backgroundInput(let enabled):
            BackgroundInputController.shared.setAllowed(enabled)
        case .welcome:
            AppDelegate.shared?.showOnboarding(restart: true)
        case .menuPresentation(let presentation):
            model.values.menuPresentation = presentation
            presentation.save()
        case .menuWidgets(let widgets):
            model.values.menuWidgets = widgets
            MenuWidgetPreferences.save(widgets)
        case .fullNumbers(let full):
            model.values.fullNumbers = full
            UserDefaults.standard.set(full, forKey: MenuBarDisplayPreferences.fullNumbersKey)
            StatsManager.shared.menuBarUpdateHandler?()
        case .notifications(let enabled):
            toggleNotifications(enabled)
        case .threshold(let field):
            commitThreshold(field)
        case .stepThreshold(let field, let delta):
            commitThreshold(field, delta: delta)
        case .calibrate:
            AppDelegate.trackClick("open_mouse_calibration")
            MouseDistanceCalibrationWindowController.shared.show()
        case .importData:
            importData()
        case .exportData:
            exportData()
        case .replay(let enabled):
            toggleReplayRecording(enabled)
        case .deleteReplay:
            deleteReplayRecords()
        case .trackpad(let enabled):
            toggleTrackpadRecording(enabled)
        case .deleteTrackpad:
            deleteTrackpadRecords()
        case .reset:
            resetStats()
        case .previewGemini:
            AppDelegate.shared?.armGeminiPreview()
        case .github:
            guard let url = URL(string: "https://github.com/Xuan-lprk/KeyTide") else { return }
            AppDelegate.trackClick("open_github_repository")
            NSWorkspace.shared.open(url)
        }
    }

    func commitThresholds() {
        guard model.values.notifications else { return }
        commitThreshold(.keyPress)
        commitThreshold(.click)
    }

    private func commitThreshold(_ field: SettingsThreshold, delta: Int = 0) {
        let stats = StatsManager.shared
        let draft = model[keyPath: field.draft]
        let current = field == .keyPress ? stats.keyPressNotifyThreshold : stats.clickNotifyThreshold
        let parsed = min(max(thresholdFormatter.number(from: draft)?.intValue ?? 0, 0), 1_000_000)
        let updated = min(max(parsed + delta, 0), 1_000_000)
        if draft != String(updated) { model[keyPath: field.draft] = String(updated) }
        guard updated != current else { return }
        switch field {
        case .keyPress: stats.keyPressNotifyThreshold = updated
        case .click: stats.clickNotifyThreshold = updated
        }
        BackgroundInputController.shared.updateThresholdPreferences()
        requestNotificationPermissionIfNeeded()
    }

    private let thresholdFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = 1_000_000
        return formatter
    }()

    private func toggleNotifications(_ enabled: Bool) {
        let stats = StatsManager.shared
        stats.notificationsEnabled = enabled
        if !enabled { commitThresholds() }
        model.values.notifications = enabled
        BackgroundInputController.shared.updateThresholdPreferences()
        if enabled { requestNotificationPermissionIfNeeded() }
    }

    private func requestNotificationPermissionIfNeeded() {
        let stats = StatsManager.shared
        guard stats.notificationsEnabled,
              stats.keyPressNotifyThreshold > 0 || stats.clickNotifyThreshold > 0 else { return }
        NotificationManager.shared.requestAuthorizationIfNeeded()
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginManager.shared.setEnabled(enabled)
            AppDelegate.trackClick("setting_launch_at_login", properties: ["enabled": enabled])
        } catch {
            showLaunchAtLoginError()
        }
        model.values.launchAtLogin = LaunchAtLoginManager.shared.isEnabled
    }

    private func showHelperRequestError() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("backgroundInput.error", comment: "")
        alert.runModal()
    }

    private lazy var exportFileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private func toggleTrackpadRecording(_ enable: Bool) {
        if enable {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("trackpad.record", comment: "")
            alert.informativeText = NSLocalizedString("trackpad.consent", comment: "")
            alert.addButton(withTitle: NSLocalizedString("replay.consent.enable", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("button.cancel", comment: ""))
            guard alert.runModal() == .alertFirstButtonReturn else { refreshTrackpad(); return }
        }
        TrackpadAppService.shared.setRecording(enable) { [weak self] _ in
            self?.refreshTrackpad()
        }
    }

    private func deleteTrackpadRecords() {
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

    private func toggleReplayRecording(_ enable: Bool) {
        if enable {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("replay.consent.title", comment: "")
            alert.informativeText = NSLocalizedString("replay.consent.body", comment: "")
            alert.addButton(withTitle: NSLocalizedString("replay.consent.enable", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("button.cancel", comment: ""))
            guard alert.runModal() == .alertFirstButtonReturn else { refreshReplay(); return }
        }
        KeyReplayRecording.shared.setEnabled(enable)
        refreshReplay()
    }

    private func deleteReplayRecords() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("replay.delete.title", comment: "")
        alert.informativeText = NSLocalizedString("replay.delete.body", comment: "")
        alert.addButton(withTitle: NSLocalizedString("replay.recording.delete", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("button.cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        KeyReplayRecording.shared.deleteAll { [weak self] ok in
            self?.refreshReplay()
            if !ok { let failure = NSAlert(); failure.messageText = NSLocalizedString("replay.delete.failed", comment: ""); failure.runModal() }
        }
    }

    private func resetStats() {
        guard !fileTransferInProgress else { return }
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

    private func exportData() {
        guard !fileTransferInProgress else { return }
        AppDelegate.trackClick("export_data")
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
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

    private func importData() {
        guard !fileTransferInProgress else { return }
        AppDelegate.trackClick("import_data")
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
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
        model.values.transfer = inProgress ? (importing ? .importing : .exporting) : nil
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
