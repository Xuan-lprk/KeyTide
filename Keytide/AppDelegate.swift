import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    private var onboardingProgress: OnboardingProgress!
    private var onboardingWindow: OnboardingWindowController?
    private var isTerminating = false
    private var installationInProgress = false
    private var helperReconnectWorkItem: DispatchWorkItem?
    private var menuBarController: MenuBarController?
    private var permissionCheckTimer: Timer?
    private var permissionCheckCount = 0
    private let maxPermissionChecks = 150 // 5分钟后停止（2秒间隔 × 150次）
    private let launchAtLoginPromptedKey = "launchAtLoginPrompted"
    private let analyticsInstallTrackedKey = "analyticsInstallTracked"
    private var shouldShowAccessibilityPromptOnLaunch: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        ApplicationIdentityMigration.migrate(defaults: .standard)
        // 必须在 trackInstallIfNeeded()/MenuBarController 任何 UserDefaults 写入之前采集，
        // 否则 fresh install 与升级用户在后续阶段已无差别。仅作为是否触发迁移提示的判据。
        let wasPreviouslyInstalled = UserDefaults.standard.bool(forKey: analyticsInstallTrackedKey)

        onboardingProgress = OnboardingProgress(defaults: .standard)
        AnalyticsManager.shared.setupIfEnabled()
        trackInstallIfNeeded()
        Self.trackEvent("app_open")

        // 初始化菜单栏控制器
        menuBarController = MenuBarController()
        applyAppIcon()
        if AppLaunchMode.current == .normal {
            _ = UpdateManager.shared
        }

        setupApplicationMenu()
        setupWindowMenu()
        if AppLaunchMode.current == .normal {
            KeyReplayRecording.shared.startObserving()
            BackgroundInputController.shared.start()
        }

        HelperXPCClient.shared.addStateObserver { [weak self] state in
            DispatchQueue.main.async {
                guard let self, !self.isTerminating, !self.installationInProgress,
                      HelperXPCClient.shared.state == state else { return }
                switch state {
                case .disconnected:
                    MonitoringStatus.shared.connectionLost()
                    self.scheduleHelperReconnect()
                case .connected:
                    self.cancelHelperReconnect()
                default: break
                }
            }
        }
        if AppLaunchMode.current == .normal, onboardingProgress.shouldPresentAutomatically {
            showOnboarding()
        } else {
            bootstrapHelperPipeline(wasPreviouslyInstalled: wasPreviouslyInstalled)
        }
        #if DEBUG
        if AppLaunchMode.current == .guiAcceptance,
           ProcessInfo.processInfo.arguments.contains("--debug-open-keyboard") {
            DispatchQueue.main.async { KeyboardHeatmapWindowController.shared.show() }
        }
        if AppLaunchMode.current == .guiAcceptance,
           ProcessInfo.processInfo.arguments.contains("--debug-open-statistics") {
            DispatchQueue.main.async { [weak self] in self?.menuBarController?.presentForGUIAcceptance() }
        }
        #endif
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // XPC invalidation releases the trackpad preview subscription. Trackpad
        // recording and its consent belong to the Helper across App launches.
        isTerminating = true
        cancelHelperReconnect()
        KeyReplayRecording.shared.shutdown()
        MonitoringStatus.shared.invalidate()
        Self.trackEvent("app_exit")
        HelperXPCClient.shared.disconnect()
        permissionCheckTimer?.invalidate()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationDidHide(_ notification: Notification) {
        StatsManager.shared.discardPresentationHistory()
    }
    
    // MARK: - Helper 启动

    private var suppressesLegacySetupPrompts: Bool {
        onboardingProgress?.usesWelcomeExperience == true || onboardingWindow?.window?.isVisible == true
    }

    func showOnboarding(restart: Bool = false) {
        guard AppLaunchMode.current == .normal else { return }
        if onboardingProgress == nil { onboardingProgress = OnboardingProgress(defaults: .standard) }
        if onboardingWindow == nil {
            let controller = OnboardingWindowController(progress: onboardingProgress)
            controller.onPrepare = { [weak self] in
                guard MonitoringStatus.shared.state != .monitoring else { return }
                self?.bootstrapHelperPipeline(wasPreviouslyInstalled: false)
            }
            controller.onRecheck = { [weak self] in
                guard let self, !self.installationInProgress, !self.isTerminating,
                      MonitoringStatus.shared.state != .monitoring,
                      MonitoringStatus.shared.state != .starting else { return }
                if case .installationFailed = MonitoringStatus.shared.state { return }
                HelperXPCClient.shared.refreshState { [weak self] state in
                    DispatchQueue.main.async {
                        guard let self, !self.isTerminating else { return }
                        if case .connected(_, true) = state { self.startMonitoringWithFeedback() }
                    }
                }
            }
            controller.onAuthorize = { [weak self] in self?.requestAccessibilityPermission(analyticsSource: "welcome") }
            controller.onRetry = { [weak self] in self?.retryMonitoring() }
            controller.onOpenStats = { [weak self] in self?.menuBarController?.showStatistics() }
            controller.onOpenKeyboard = { KeyboardHeatmapWindowController.shared.show() }
            controller.onOpenExample = { KeyboardHeatmapWindowController.shared.showExample() }
            controller.setLogin = { try LaunchAtLoginManager.shared.setEnabled($0) }
            controller.loginEnabled = { LaunchAtLoginManager.shared.isEnabled }
            controller.onClose = { [weak self] in
                self?.permissionCheckTimer?.invalidate()
                self?.permissionCheckTimer = nil
                DispatchQueue.main.async { [weak self] in
                    guard self?.onboardingWindow?.window?.isVisible == false else { return }
                    self?.onboardingWindow = nil
                    StatsManager.shared.discardPresentationHistory()
                }
            }
            onboardingWindow = controller
        }
        onboardingWindow?.show(restart: restart)
    }

    private func bootstrapHelperPipeline(wasPreviouslyInstalled: Bool) {
        guard !isTerminating, !installationInProgress else { return }
        cancelHelperReconnect()
        HelperXPCClient.shared.setEventSink(RemoteEventProcessor.shared)
        if AppLaunchMode.current == .guiAcceptance {
            NSLog("[GUI Acceptance] Using installed Helper only; installation, LaunchAgent management and permission migration are disabled")
            connectHelperAndStart()
            return
        }
        installationInProgress = true
        MonitoringStatus.shared.begin()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try HelperSupervisor.shared.ensureInstalled()
                NSLog("[AppDelegate] helper installed + launchd registered")
            } catch {
                NSLog("[AppDelegate] HelperSupervisor.ensureInstalled failed: \(error)")
                DispatchQueue.main.async {
                    guard let self, !self.isTerminating else { return }
                    self.installationInProgress = false
                    MonitoringStatus.shared.installationFailed(error.localizedDescription)
                }
                return
            }
            DispatchQueue.main.async {
                guard let self, !self.isTerminating else { return }
                self.installationInProgress = false
                MonitoringStatus.shared.invalidate()
                Task { @MainActor in
                    if !self.suppressesLegacySetupPrompts {
                        HelperMigrationPresenter.shared.showIfNeeded(wasPreviouslyInstalled: wasPreviouslyInstalled)
                    }
                    self.connectHelperAndStart()
                }
            }
        }
    }

    private func connectHelperAndStart() {
        guard !isTerminating, !installationInProgress else { return }
        cancelHelperReconnect()
        HelperXPCClient.shared.connect { [weak self] state in
            DispatchQueue.main.async {
                guard let self = self, !self.isTerminating, !self.installationInProgress,
                      HelperXPCClient.shared.state == state else { return }
                NSLog("[AppDelegate] helper xpc state = \(state)")
                switch state {
                case .connected(let version, let granted):
                    guard version >= HelperLocations.inputOwnershipVersion,
                          AppLaunchMode.current.allowsHelperVersion(version, expected: HelperLocations.interfaceVersion) else {
                        NSLog("[AppDelegate] Helper protocol mismatch (installed=%d expected=%d)", version, HelperLocations.interfaceVersion)
                        HelperXPCClient.shared.disconnect()
                        MonitoringStatus.shared.installationFailed(NSLocalizedString("monitoring.helperVersionMismatch", comment: ""))
                        return
                    }
                    if granted {
                        self.startMonitoringWithFeedback()
                    } else {
                        MonitoringStatus.shared.invalidate()
                        guard AppLaunchMode.current == .normal else {
                            NSLog("[GUI Acceptance] Installed Helper lacks Accessibility permission; GUI remains available without monitoring or permission changes")
                            return
                        }
                        if self.shouldShowAccessibilityPromptOnLaunch && !self.suppressesLegacySetupPrompts {
                            self.showPermissionAlert()
                        } else {
                            print("开发模式启动：helper 未获辅助功能授权，跳过启动提示")
                        }
                        if !self.suppressesLegacySetupPrompts { self.startPermissionPolling() }
                    }
                case .disconnected(let reason):
                    guard AppLaunchMode.current == .normal else {
                        NSLog("[GUI Acceptance] Installed Helper unavailable: %@; no install or reconnect attempted", reason)
                        return
                    }
                    NSLog("[AppDelegate] helper disconnected: \(reason); retry in 5s")
                    self.scheduleHelperReconnect()
                default:
                    break
                }
            }
        }
    }

    private func scheduleHelperReconnect() {
        guard AppLaunchMode.current == .normal, !isTerminating, !installationInProgress,
              helperReconnectWorkItem == nil else { return }
        guard case .disconnected = HelperXPCClient.shared.state else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.helperReconnectWorkItem = nil
            guard AppLaunchMode.current == .normal, !self.isTerminating, !self.installationInProgress,
                  case .disconnected = HelperXPCClient.shared.state else { return }
            self.connectHelperAndStart()
        }
        helperReconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func cancelHelperReconnect() {
        helperReconnectWorkItem?.cancel()
        helperReconnectWorkItem = nil
    }

    private func startMonitoringWithFeedback() {
        guard !isTerminating else { return }
        let token = MonitoringStatus.shared.begin()
        HelperXPCClient.shared.startMonitoring { [weak self] ok, code in
            DispatchQueue.main.async {
                guard let self, !self.isTerminating else { return }
                if MonitoringStatus.shared.finish(token: token, ok: ok, code: code) {
                    self.promptLaunchAtLoginIfNeeded()
                }
            }
        }
    }

    func retryMonitoring() {
        guard AppLaunchMode.current == .normal, !isTerminating else { return }
        switch MonitoringStatus.shared.state {
        case .installationFailed:
            bootstrapHelperPipeline(wasPreviouslyInstalled: false)
        case .starting: return
        case .failed(code: 1):
            HelperXPCClient.shared.refreshState { [weak self] _ in
                DispatchQueue.main.async {
                    self?.requestAccessibilityPermission(analyticsSource: "monitoring_retry")
                }
            }
        default:
            if isHelperAccessibilityGranted() { startMonitoringWithFeedback() }
            else { requestAccessibilityPermission(analyticsSource: "monitoring_retry") }
        }
    }

    private func isHelperAccessibilityGranted() -> Bool {
        if case .connected(_, let granted) = HelperXPCClient.shared.state {
            return granted
        }
        return false
    }

    func requestAccessibilityPermission(analyticsSource: String) {
        guard AppLaunchMode.current == .normal else {
            NSLog("[GUI Acceptance] Accessibility requests are disabled")
            return
        }
        if isHelperAccessibilityGranted() {
            handleAccessibilityPermissionGranted()
            return
        }

        Self.trackClick("request_accessibility_permission", properties: [
            "permission": "accessibility",
            "source": analyticsSource
        ])
        // 先让 helper 调一次 AXIsProcessTrustedWithOptions，把自己写进系统设置的
        // 辅助功能列表；再跳转到那个 pane 方便用户授权。
        HelperXPCClient.shared.promptAccessibility { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if granted {
                    self.handleAccessibilityPermissionGranted()
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.openAccessibilitySettingsPane()
                    self?.startPermissionPolling()
                }
            }
        }
    }

    private func openAccessibilitySettingsPane() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("permission.title", comment: "")
        if let appIcon = NSApp.applicationIconImage {
            alert.icon = makeRoundedAlertIcon(from: appIcon)
        }
        let permissionMessage = NSLocalizedString("permission.message", comment: "")
        let reinstallTip = String(format: NSLocalizedString("permission.reinstallTip", comment: ""),
                                  HelperLocations.installedHelperURL.path)
        let textParts = [permissionMessage, reinstallTip].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        alert.informativeText = textParts.joined(separator: "\n\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("permission.openSettings", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("permission.later", comment: ""))

        if alert.runModal() == .alertFirstButtonReturn {
            requestAccessibilityPermission(analyticsSource: "launch_alert")
        }
    }

    private func handleAccessibilityPermissionGranted() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
        startMonitoringWithFeedback()
    }

    private func startPermissionPolling() {
        permissionCheckTimer?.invalidate()
        permissionCheckCount = 0
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            self.permissionCheckCount += 1

            // 每次 poll 都重新握手，以便读 helper 的最新授权状态
            HelperXPCClient.shared.refreshState { state in
                DispatchQueue.main.async {
                    if case .connected(_, let granted) = state, granted {
                        timer.invalidate()
                        self.permissionCheckTimer = nil
                        self.handleAccessibilityPermissionGranted()
                        Self.trackEvent("permission_granted", properties: ["permission": "accessibility"])
                        print("权限已授予，helper 开始监听")
                    }
                }
            }

            if self.permissionCheckCount >= self.maxPermissionChecks {
                timer.invalidate()
                self.permissionCheckTimer = nil
                print("权限检查超时（5分钟），请手动在系统设置中授予 KeytideHelper 辅助功能权限")
            }
        }

        if let permissionCheckTimer {
            RunLoop.main.add(permissionCheckTimer, forMode: .common)
        }
    }

    private func promptLaunchAtLoginIfNeeded() {
        guard AppLaunchMode.current == .normal, !suppressesLegacySetupPrompts else { return }
        guard isHelperAccessibilityGranted() else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: launchAtLoginPromptedKey) else { return }
        defaults.set(true, forKey: launchAtLoginPromptedKey)

        if LaunchAtLoginManager.shared.isEnabled {
            return
        }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("launchAtLogin.prompt.title", comment: "")
        alert.informativeText = NSLocalizedString("launchAtLogin.prompt.message", comment: "")
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("launchAtLogin.prompt.enable", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("launchAtLogin.prompt.later", comment: ""))

        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try LaunchAtLoginManager.shared.setEnabled(true)
            } catch {
                showLaunchAtLoginError()
            }
        }
    }

    private func showLaunchAtLoginError() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("launchAtLogin.error.title", comment: "")
        alert.informativeText = NSLocalizedString("launchAtLogin.error.message", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("button.ok", comment: ""))
        alert.runModal()
    }
    
    private func makeRoundedAlertIcon(from image: NSImage) -> NSImage {
        let targetSize: CGFloat = 64
        let rect = NSRect(x: 0, y: 0, width: targetSize, height: targetSize)
        let icon = NSImage(size: rect.size)
        icon.lockFocus()
        let radius = targetSize * 0.22
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.addClip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        icon.unlockFocus()
        return icon
    }

    private func applyAppIcon() {
        guard let appIcon = NSImage(named: "AppIcon") else {
            return
        }
        NSApp.applicationIconImage = appIcon
    }

    private func setupApplicationMenu() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu else { return }
        if let about = menu.items.first(where: { $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)) }) {
            about.title = NSLocalizedString("menu.about", comment: "")
            about.target = self
            about.action = #selector(showProjectAbout)
        }
        menu.items.first(where: { $0.action == #selector(NSApplication.terminate(_:)) })?.title =
            NSLocalizedString("menu.quitApp", comment: "")
    }

    @objc private func showProjectAbout() {
        let credits = NSMutableAttributedString(string:
            NSLocalizedString("about.maintainer", comment: "") + " Xuan-lprk\n")
        credits.append(NSAttributedString(string: "github.com/Xuan-lprk/KeyTide",
            attributes: [.link: URL(string: "https://github.com/Xuan-lprk/KeyTide")!]))
        credits.append(NSAttributedString(string: "\n\n" + NSLocalizedString("about.upstreamCredit", comment: "")))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Keytide",
            .credits: credits
        ])
    }

    private func setupWindowMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let windowTitle = NSLocalizedString("menu.window", comment: "")
        if mainMenu.items.contains(where: { $0.title == windowTitle }) {
            return
        }
        let windowMenuItem = NSMenuItem(title: windowTitle, action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: windowTitle)
        let closeTitle = NSLocalizedString("menu.closeWindow", comment: "")
        let closeItem = NSMenuItem(title: closeTitle, action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = [.command]
        windowMenu.addItem(closeItem)
        windowMenuItem.submenu = windowMenu

        let insertIndex = min(1, mainMenu.items.count)
        mainMenu.insertItem(windowMenuItem, at: insertIndex)
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Analytics

    private func trackInstallIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: analyticsInstallTrackedKey) else { return }
        Self.trackEvent("app_install", properties: ["install_utc": AnalyticsManager.shared.firstOpenUTC()])
        defaults.set(true, forKey: analyticsInstallTrackedKey)
    }

    static func trackEvent(_ eventName: String, properties: [String: Any]? = nil) {
        AnalyticsManager.shared.trackEvent(eventName, properties: properties)
    }

    static func trackPageView(_ pageName: String, properties: [String: Any]? = nil) {
        AnalyticsManager.shared.trackPageView(pageName, properties: properties)
    }

    static func trackClick(_ elementName: String, properties: [String: Any]? = nil) {
        AnalyticsManager.shared.trackClick(elementName, properties: properties)
    }
}
