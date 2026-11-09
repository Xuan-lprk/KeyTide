import Cocoa
import SwiftUI

enum DynamicIconColorStyle: String {
    case icon
    case dot
}

/// Presentation-only preferences; existing metric visibility remains in StatsManager.
enum MenuBarDisplayPreferences {
    static let singleLineKey = "menuBar.singleLine.v1"
    static let fullNumbersKey = "menuBar.fullNumbers.v1"

    static func number(_ value: Int, full: Bool) -> String {
        if !full { return formatMenuBarCompactNumber(value) }
        return value.formatted(.number.grouping(.automatic))
    }
}

/// 菜单栏控制器
class MenuBarController {

    private var statusItem: NSStatusItem!
    private var statusView: MenuBarStatusView?
    private var contextMenu: NSMenu?
    private var popover: NSPopover!
    private var popoverStyle: MenuUIStyle = .standard
    private var styleControllers: [String: NSViewController] = [:]
    private var eventMonitor: Any?
    private let dynamicIconColorStyleKey = "dynamicIconColorStyle"
    private let menuBarUpdateInterval: TimeInterval = 0.1
    private var pendingMenuBarUpdate: DispatchWorkItem?
    private var lastMenuBarUpdateTime: TimeInterval = 0

    init() {
        setupStatusItem()
        setupContextMenu()
        setupPopover()
        setupEventMonitor()
        StatsManager.shared.menuBarUpdateHandler = { [weak self] in
            self?.scheduleMenuBarUpdate()
        }
    }

    deinit {
        StatsManager.shared.menuBarUpdateHandler = nil
        pendingMenuBarUpdate?.cancel()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - 设置状态栏项

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let statusView = MenuBarStatusView()
        statusView.onClick = { [weak self] in
            self?.togglePopover()
        }
        statusView.onRightClick = { [weak self] in
            self?.showContextMenu()
        }
        statusItem.view = statusView
        self.statusView = statusView
        updateMenuBarAppearance()
    }

    private func setupContextMenu() {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: NSLocalizedString("settings.title", comment: ""),
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let mechanicalKeyboardItem = NSMenuItem(
            title: NSLocalizedString("keyboardVisualization.entry", comment: ""),
            action: #selector(openMechanicalKeyboard),
            keyEquivalent: ""
        )
        mechanicalKeyboardItem.target = self
        menu.addItem(mechanicalKeyboardItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: NSLocalizedString("button.quit", comment: ""),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        contextMenu = menu
    }

    // MARK: - 设置弹出面板

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popoverStyle = MenuUIStyle.current
        let controller = styleControllers[popoverStyle.rawValue] ?? (popoverStyle == .geek
            ? GeekStatsPopoverViewController() : StatsPopoverViewController())
        styleControllers[popoverStyle.rawValue] = controller
        let statsPopoverViewController = controller as! MenuStatsPresenting
        statsPopoverViewController.preferredSizeDidChange = { [weak self, weak controller] targetSize in
            guard let self, let controller, self.popover.contentViewController === controller else { return }
            self.popover.contentSize = targetSize
        }
        popover.contentViewController = controller
        statsPopoverViewController.prepareForPopoverPresentation()
        popover.contentSize = statsPopoverViewController.preferredContentSize
    }

    // MARK: - 设置事件监听（点击外部关闭弹窗）

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let popover = self?.popover, popover.isShown {
                popover.performClose(nil)
            }
        }
    }

    // MARK: - 操作

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showContextMenu() {
        closePopover()
        guard let menu = contextMenu else { return }
        statusItem.popUpMenu(menu)
    }

    @objc private func openSettings() {
        AppDelegate.trackClick("context_menu_settings")
        SettingsWindowController.shared.show()
    }

    @objc private func openMechanicalKeyboard() {
        AppDelegate.trackClick("context_menu_mechanical_keyboard")
        KeyboardHeatmapWindowController.shared.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func showPopover() {
        if popoverStyle != MenuUIStyle.current { setupPopover() }
        // 先激活应用，确保弹窗可以接收焦点
        NSApp.activate(ignoringOtherApps: true)

        if let statsPopoverViewController = popover.contentViewController as? MenuStatsPresenting {
            statsPopoverViewController.prepareForPopoverPresentation()
            popover.contentSize = statsPopoverViewController.preferredContentSize
        }

        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let view = statusItem.view {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else {
            return
        }

        // 确保 popover 窗口成为 key window
        popover.contentViewController?.view.window?.makeKey()
        AppDelegate.trackClick("tray_icon")
        AppDelegate.trackPageView("stats_popup")
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    #if DEBUG
    func presentForGUIAcceptance() {
        guard AppLaunchMode.current == .guiAcceptance else { return }
        // The status item's window is attached after applicationDidFinishLaunching.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.showPopover()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                NSLog("[GUI Acceptance] Statistics popover shown=\(self.popover.isShown) size=\(self.popover.contentSize) anchorVisible=\(self.statusItem.view?.window?.isVisible ?? false)")
            }
        }
    }
    #endif

    private func scheduleMenuBarUpdate() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.scheduleMenuBarUpdate()
            }
            return
        }

        guard pendingMenuBarUpdate == nil else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastMenuBarUpdateTime
        guard elapsed < menuBarUpdateInterval else {
            performMenuBarUpdate()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingMenuBarUpdate = nil
            self.performMenuBarUpdate()
        }
        pendingMenuBarUpdate = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (menuBarUpdateInterval - elapsed),
            execute: workItem
        )
    }

    private func performMenuBarUpdate() {
        lastMenuBarUpdateTime = ProcessInfo.processInfo.systemUptime
        updateMenuBarAppearance()
    }

    // MARK: - 菜单栏显示样式

    private func updateMenuBarAppearance() {
        let stats = StatsManager.shared.displayCurrentStats()
        let full = UserDefaults.standard.bool(forKey: MenuBarDisplayPreferences.fullNumbersKey)
        let parts = (
            keys: StatsManager.shared.showKeyPressesInMenuBar ? MenuBarDisplayPreferences.number(stats.keyPresses, full: full) : "",
            clicks: StatsManager.shared.showMouseClicksInMenuBar ? MenuBarDisplayPreferences.number(stats.totalClicks, full: full) : ""
        )
        let tintColor = StatsManager.shared.enableDynamicIconColor
            ? StatsManager.shared.currentIconTintColor
            : nil
        let styleValue = UserDefaults.standard.string(forKey: dynamicIconColorStyleKey) ?? DynamicIconColorStyle.icon.rawValue
        let minimalMode = StatsManager.shared.minimalMenuBarMode
        let style = minimalMode ? .dot : (DynamicIconColorStyle(rawValue: styleValue) ?? .icon)

        if let statusView = statusView {
            statusView.configure(singleLine: UserDefaults.standard.bool(forKey: MenuBarDisplayPreferences.singleLineKey), fullNumbers: full)
            statusView.update(keysText: parts.keys, clicksText: parts.clicks)
            let summary = "\(NSLocalizedString("setting.showKeyPresses", comment: "")): \(stats.keyPresses.formatted()) · \(NSLocalizedString("setting.showMouseClicks", comment: "")): \(stats.totalClicks.formatted())"
            statusView.toolTip = summary
            statusView.setAccessibilityLabel(summary)
            statusView.updateIconColor(tintColor,
                                       style: style,
                                       isMinimalMode: minimalMode,
                                       showsColorDot: minimalMode &&
                                           StatsManager.shared.enableDynamicIconColor &&
                                           StatsManager.shared.currentInputRatePerSecond > 0)
            statusItem.length = statusView.intrinsicContentSize.width
        } else if let button = statusItem.button {
            button.attributedTitle = makeStatusTitle(keysText: parts.keys, clicksText: parts.clicks)
            button.contentTintColor = style == .icon ? tintColor : nil
        }

    }

    private func makeStatusTitle(keysText: String, clicksText: String) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let textAttributes: [NSAttributedString.Key: Any] = [.font: font]
        let result = NSMutableAttributedString()

        func appendText(_ text: String) {
            result.append(NSAttributedString(string: text, attributes: textAttributes))
        }

        func appendAppIcon() {
            guard let appIcon = NSImage(named: "MenuIcon") else {
                return
            }
            let resizedIcon = NSImage(size: NSSize(width: 13, height: 13))
            resizedIcon.lockFocus()
            appIcon.draw(in: NSRect(x: 0, y: 0, width: 13, height: 13),
                        from: NSRect(origin: .zero, size: appIcon.size),
                        operation: .copy,
                        fraction: 1.0)
            resizedIcon.unlockFocus()
            resizedIcon.isTemplate = true

            let attachment = NSTextAttachment()
            attachment.image = resizedIcon
            attachment.bounds = NSRect(x: 0, y: -1, width: 13, height: 13)
            result.append(NSAttributedString(attachment: attachment))
        }

        appendAppIcon()

        if !keysText.isEmpty {
            appendText(" ")
            appendText(keysText)
        }

        if !clicksText.isEmpty {
            appendText(" ")
            appendText(clicksText)
        }

        return result
    }
}

// MARK: - 菜单栏自定义视图

final class MenuBarStatusViewModel: ObservableObject {
    @Published var singleLine = false
    @Published var keysText: String = "0"
    @Published var clicksText: String = "0"
    @Published var iconColor: NSColor?
    @Published var colorStyle: DynamicIconColorStyle = .icon
    @Published var isMinimalMode: Bool = false
    @Published var showsColorDot: Bool = false
}

struct MenuBarStatusSwiftUIView: View {
    @ObservedObject var viewModel: MenuBarStatusViewModel
    @Environment(\.colorScheme) private var colorScheme

    private static let menuIcon: NSImage? = {
        guard let appIcon = NSImage(named: "MenuIcon") else {
            return nil
        }
        let resizedIcon = NSImage(size: NSSize(width: 18, height: 18))
        resizedIcon.lockFocus()
        appIcon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18),
                    from: NSRect(origin: .zero, size: appIcon.size),
                    operation: .copy,
                    fraction: 1.0)
        resizedIcon.unlockFocus()
        resizedIcon.isTemplate = true
        return resizedIcon
    }()

    var body: some View {
        let hasText = !viewModel.keysText.isEmpty || !viewModel.clicksText.isEmpty
        let horizontalPadding: CGFloat = viewModel.isMinimalMode ? 3 : (hasText ? 6 : 4)

        HStack(spacing: 4) {
            if !viewModel.isMinimalMode {
                ZStack(alignment: .topLeading) {
                    if let icon = Self.menuIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .renderingMode(.template)
                            .frame(width: 18, height: 18, alignment: .center)
                            .foregroundStyle(iconTint)
                    }

                    if let dotColor = dotColor {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 6, height: 6)
                            .offset(x: -3, y: -3)
                    }
                }
                .frame(width: 18, height: 18, alignment: .center)
            }

            if hasText {
                let layout = viewModel.singleLine
                    ? AnyLayout(HStackLayout(alignment: .center, spacing: 8))
                    : AnyLayout(VStackLayout(alignment: .trailing, spacing: 0))
                layout {
                    if !viewModel.keysText.isEmpty {
                        MenuBarValueText(text: viewModel.keysText, weight: .semibold, size: viewModel.singleLine ? 11 : 10)
                    }

                    if !viewModel.clicksText.isEmpty {
                        MenuBarValueText(text: viewModel.clicksText, weight: .medium, size: viewModel.singleLine ? 11 : 10)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if viewModel.isMinimalMode, let dotColor = dotColor {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 6, height: 6)
                            .offset(x: -8, y: 3)
                    }
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, !viewModel.singleLine && !viewModel.keysText.isEmpty && !viewModel.clicksText.isEmpty ? 0 : 2)
        .frame(minHeight: 20, alignment: .center)
    }

    private var iconTint: Color {
        if viewModel.colorStyle == .icon, let color = viewModel.iconColor {
            return Color(nsColor: color)
        }
        if colorScheme == .dark {
            return Color(red: 233 / 255, green: 241 / 255, blue: 245 / 255)
        }
        return Color(nsColor: .controlTextColor)
    }

    private var dotColor: Color? {
        guard viewModel.colorStyle == .dot, viewModel.showsColorDot else {
            return nil
        }
        return Color(nsColor: viewModel.iconColor ?? .secondaryLabelColor)
    }
}

private struct MenuBarValueText: View {
    let text: String
    let weight: Font.Weight

    let size: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: weight))
            .frame(height: size == 10 ? 11 : 16)
            .monospacedDigit()
            .foregroundStyle(Color(nsColor: .labelColor))
    }
}

class MenuBarStatusView: NSView {
    private let viewModel = MenuBarStatusViewModel()
    private var hostingView: NSHostingView<MenuBarStatusSwiftUIView>?
    private var currentKeysText: String = "0"
    private var currentClicksText: String = "0"
    private var singleLine = false
    private var fullNumbers = false
    private var reservedTextWidth: CGFloat = 0
    private var visibilitySignature = ""
    private var isMinimalMode = false
    private var showsColorDot = false

    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        let rootView = MenuBarStatusSwiftUIView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        self.hostingView = hostingView
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    override var intrinsicContentSize: NSSize {
        let hasText = !currentKeysText.isEmpty || !currentClicksText.isEmpty
        let horizontalPadding: CGFloat = isMinimalMode ? 6 : (hasText ? 12 : 8)
        let iconWidth: CGFloat = isMinimalMode ? 0 : 18
        let leadingVisualWidth = iconWidth
        let iconTextSpacing: CGFloat = leadingVisualWidth > 0 && hasText ? 4 : 0
        let keyWidth = Self.valueWidth(for: currentKeysText, weight: .semibold, size: singleLine ? 11 : 10)
        let clickWidth = Self.valueWidth(for: currentClicksText, weight: .medium, size: singleLine ? 11 : 10)
        let measured = singleLine ? keyWidth + clickWidth + (keyWidth > 0 && clickWidth > 0 ? 8 : 0) : max(keyWidth, clickWidth)
        // Keep width stable as counters change; only explicit configuration resets it.
        reservedTextWidth = max(reservedTextWidth, measured)
        let textWidth = reservedTextWidth
        let width = ceil(horizontalPadding + leadingVisualWidth + iconTextSpacing + textWidth + 1)

        if let hostingView = hostingView {
            return NSSize(width: width, height: max(hostingView.fittingSize.height, 20))
        }
        return NSSize(width: width, height: 20)
    }

    func configure(singleLine: Bool, fullNumbers: Bool) {
        if self.singleLine != singleLine || self.fullNumbers != fullNumbers {
            reservedTextWidth = 0
        }
        self.singleLine = singleLine
        self.fullNumbers = fullNumbers
        viewModel.singleLine = singleLine
        invalidateIntrinsicContentSize()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    func update(keysText: String, clicksText: String) {
        let updateBlock = {
            let signature = "\(keysText.isEmpty)-\(clicksText.isEmpty)"
            if self.visibilitySignature != signature { self.reservedTextWidth = 0 }
            self.visibilitySignature = signature
            self.currentKeysText = keysText
            self.currentClicksText = clicksText
            self.viewModel.keysText = keysText
            self.viewModel.clicksText = clicksText
        }

        if Thread.isMainThread {
            updateBlock()
        } else {
            DispatchQueue.main.async {
                updateBlock()
            }
        }

        invalidateIntrinsicContentSize()
        hostingView?.invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private static func valueWidth(for text: String, weight: NSFont.Weight, size: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    func updateIconColor(_ color: NSColor?, style: DynamicIconColorStyle, isMinimalMode: Bool, showsColorDot: Bool) {
        let updateBlock = {
            self.viewModel.iconColor = color
            self.viewModel.colorStyle = style
            self.viewModel.isMinimalMode = isMinimalMode && (!self.currentKeysText.isEmpty || !self.currentClicksText.isEmpty)
            self.viewModel.showsColorDot = showsColorDot || (style == .dot && color != nil)
            self.isMinimalMode = self.viewModel.isMinimalMode
            self.showsColorDot = showsColorDot || (style == .dot && color != nil)
        }

        if Thread.isMainThread {
            updateBlock()
        } else {
            DispatchQueue.main.async {
                updateBlock()
            }
        }

        invalidateIntrinsicContentSize()
        hostingView?.invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return self
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onRightClick?()
            return
        }
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}
