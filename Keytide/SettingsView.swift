import SwiftUI

enum SettingsPage: String, CaseIterable {
    case general, appearance, notifications, data

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "menubar.rectangle"
        case .notifications: return "bell"
        case .data: return "externaldrive"
        }
    }

    var navigationTitle: LocalizedStringKey { LocalizedStringKey("settings.navigation." + rawValue) }
    var title: LocalizedStringKey { LocalizedStringKey("settings.page." + rawValue) }
    var help: LocalizedStringKey { LocalizedStringKey("settings.page." + rawValue + ".help") }
}

enum SettingsThreshold {
    case keyPress, click

    var draft: ReferenceWritableKeyPath<SettingsModel, String> {
        switch self {
        case .keyPress: return \.keyThreshold
        case .click: return \.clickThreshold
        }
    }
}

enum SettingsAction {
    case trackApps(Bool), launchAtLogin(Bool), backgroundInput(Bool), welcome
    case menuPresentation(MenuPresentation), menuWidgets([MenuWidget]), fullNumbers(Bool)
    case notifications(Bool), threshold(SettingsThreshold), stepThreshold(SettingsThreshold, Int)
    case calibrate, importData, exportData
    case replay(Bool), deleteReplay, trackpad(Bool), deleteTrackpad
    case reset, github, previewGemini
}

final class SettingsModel: ObservableObject {
    enum Transfer { case importing, exporting }

    struct Values {
        var trackApps = false
        var launchAtLogin = false
        var backgroundInput = false
        var backgroundStatus: String?
        var menuPresentation = MenuPresentation.widgets
        var menuWidgets: [MenuWidget] = []
        var fullNumbers = false
        var notifications = false
        var replay = false
        var replayAvailable = true
        var replayStatus = "replay.recording.off"
        var trackpad = false
        var trackpadAvailable = false
        var trackpadStatus = "trackpad.helper.unavailable"
        var transfer: Transfer?
    }

    @Published var page: SettingsPage
    @Published var values = Values()
    @Published var keyThreshold = "0"
    @Published var clickThreshold = "0"
    var send: (SettingsAction) -> Void = { _ in }

    init(page: SettingsPage) { self.page = page }

    func selectPage(_ page: SettingsPage) {
        guard page != self.page else { return }
        if self.page == .notifications, values.notifications {
            send(.threshold(.keyPress))
            send(.threshold(.click))
        }
        self.page = page
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @FocusState private var focusedPage: SettingsPage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var expandedMenuWidget: UUID?
    @State private var widgetDragScope = UUID().uuidString
    @State private var widgetDropTarget: UUID?
    @State private var hoveredWidgetKind: MenuWidgetKind?

    private let rowHeight: CGFloat = 40
    private let rowSpacing: CGFloat = 4
    private let contentWidth: CGFloat = 680
    private let contentInset: CGFloat = 32

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            contentPane
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focusedPage = model.page }
        .onChange(of: model.page) { focusedPage = $0 }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                    .overlay { SettingsAppIconClickTarget { model.send(.previewGemini) } }
                    .accessibilityHidden(true)
                Text("Keytide").font(.system(size: 17, weight: .semibold))
            }

            VStack(spacing: rowSpacing) {
                ForEach(SettingsPage.allCases, id: \.self) { page in
                    Button {
                        selectPage(page)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: page.symbol)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(model.page == page ? Color.accentColor : Color.secondary)
                                .frame(width: 18)
                                .accessibilityHidden(true)
                            Text(page.navigationTitle)
                                .font(.system(size: 13, weight: model.page == page ? .semibold : .medium))
                                .foregroundStyle(model.page == page ? Color.primary : Color.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 13)
                        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .focused($focusedPage, equals: page)
                    .overlay {
                        let isFocused = focusedPage == page
                        let emphasized = isFocused || contrast == .increased
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(emphasized ? 0.65 : 0.30),
                                          lineWidth: isFocused ? 1.5 : 1)
                            .padding(.horizontal, 1)
                            .padding(.vertical, 2)
                            .opacity((focusedPage ?? model.page) == page ? 1 : 0)
                            .transaction { $0.animation = nil }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .accessibilityAddTraits(model.page == page ? .isSelected : [])
                }
            }
            .background(alignment: .top) {
                let selectedIndex = SettingsPage.allCases.firstIndex(of: model.page) ?? 0
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(contrast == .increased ? 0.28 : 0.17))
                    .frame(height: rowHeight - 4)
                    .padding(.horizontal, 1)
                    .offset(y: 2 + CGFloat(selectedIndex) * (rowHeight + rowSpacing))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.page)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .modifier(SettingsSidebarFocusEffect())
            .onMoveCommand(perform: moveSelection)

            Spacer(minLength: 16)
            sidebarFooter
        }
        .padding(.horizontal, 14)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 198)
        .background(.regularMaterial)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("settings.localOnly")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Text(Self.version)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button { model.send(.github) } label: {
                    Group {
                        if let icon = Self.githubIcon {
                            Image(nsImage: icon).resizable().frame(width: 15, height: 15)
                        } else {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                        }
                    }
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("settings.github")
                .help("settings.github.tooltip")
            }
        }
        .padding(.horizontal, 3)
    }

    private var contentPane: some View {
        VStack(spacing: 0) {
            header
                .frame(maxWidth: contentWidth, alignment: .leading)
                .padding(.horizontal, contentInset)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    pageContents
                }
                .frame(maxWidth: contentWidth, alignment: .leading)
                .padding(.horizontal, contentInset)
                .padding(.top, 20)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .id(model.page)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.page.title)
                .font(.system(size: 28, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            SettingsDetail(model.page.help, size: 13)
            SettingsRule().padding(.top, 12)
        }
        .padding(.top, 22)
    }

    @ViewBuilder private var pageContents: some View {
        switch model.page {
        case .general: general
        case .appearance:
            menuBarSettings
            if model.values.menuPresentation == .widgets {
                menuWidgetLibrary
                menuWidgetSettings
            }
        case .notifications: notifications
        case .data: data
        }
    }

    @ViewBuilder private var general: some View {
        SettingsSection("settings.section.tracking") {
            switchRow("setting.appStatsEnabled", isOn: binding(\.trackApps, action: SettingsAction.trackApps))
            SettingsRule(inset: 16)
            switchRow("backgroundInput.title", help: "backgroundInput.help",
                      status: model.values.backgroundStatus, isOn: binding(\.backgroundInput, action: SettingsAction.backgroundInput))
        }
        SettingsSection("settings.section.startup") {
            switchRow("button.launchAtLogin", help: "settings.appLogin.help",
                      isOn: binding(\.launchAtLogin, action: SettingsAction.launchAtLogin))
            SettingsRule(inset: 16)
            SettingsRow("settings.welcomeGuide") {
                Button("settings.openGuide") { model.send(.welcome) }
                    .accessibilityLabel("welcome.reopen")
            }
        }
    }

    private var menuBarSettings: some View {
        SettingsSection("settings.section.menuBar") {
            SettingsRow("settings.menuPresentation", controlHasLabel: true) {
                Picker("settings.menuPresentation", selection: binding(\.menuPresentation, action: SettingsAction.menuPresentation)) {
                    ForEach(MenuPresentation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            SettingsRule(inset: 16)
            SettingsRow("settings.menuDisplay.numbers", controlHasLabel: true) {
                Picker("settings.menuDisplay.numbers", selection: binding(\.fullNumbers, action: SettingsAction.fullNumbers)) {
                    Text("settings.menuDisplay.compact").tag(false)
                    Text("settings.menuDisplay.full").tag(true)
                }
                .labelsHidden()
            }
            SettingsRule(inset: 16)
            SettingsRow("settings.menuDisplay.preview") {
                SettingsMenuBarPreview(fullNumbers: model.values.fullNumbers)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .pickerStyle(.menu)
    }

    private var menuWidgetLibrary: some View {
        SettingsSection("menu.widgets.library") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                ForEach(MenuWidgetKind.allCases) { kind in
                    Button {
                        let widget = MenuWidget(kind: kind, metric: kind.metrics.first ?? .keys)
                        expandedMenuWidget = widget.id
                        model.send(.menuWidgets(model.values.menuWidgets + [widget]))
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: kind.symbol)
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(kind.title).lineLimit(1)
                            Spacer(minLength: 6)
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(hoveredWidgetKind == kind ? Color.accentColor : .secondary)
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(SettingsWidgetTileStyle(isHovered: hoveredWidgetKind == kind))
                    .onHover { hovering in
                        if hovering { hoveredWidgetKind = kind }
                        else if hoveredWidgetKind == kind { hoveredWidgetKind = nil }
                    }
                    .accessibilityLabel(Text(String(format: NSLocalizedString("settings.widgets.addNamed", comment: ""), kind.title)))
                }
            }
            .padding(12)
        }
    }

    private var menuWidgetSettings: some View {
        let widgets = model.values.menuWidgets
        return SettingsSection("menu.widgets.title") {
            if widgets.isEmpty {
                SettingsDetail("menu.widgets.empty")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                widgetLayoutPreview(widgets)
                ForEach(Array(widgets.enumerated()), id: \.element.id) { index, widget in
                    SettingsRule(inset: 16)
                    widgetEditorRow(widget, at: index, total: widgets.count)
                }
            }
        }
        .pickerStyle(.menu)
    }

    private func widgetEditorRow(_ widget: MenuWidget, at index: Int, total: Int) -> some View {
        let isExpanded = expandedMenuWidget == widget.id
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    expandedMenuWidget = isExpanded ? nil : widget.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                            .accessibilityHidden(true)
                        Image(systemName: widget.kind.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        Text(widget.kind.title).font(.system(size: 13, weight: .medium))
                        if !widget.kind.metrics.isEmpty {
                            Text(widget.displayMetric.title).font(.system(size: 11)).foregroundStyle(.secondary)
                        } else if widget.kind == .heatmap {
                            heatmapSwatch(widget)
                        } else {
                            Text(widget.style.title).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                widgetButton("chevron.up", title: "menu.widgets.up") { moveWidget(at: index, by: -1) }
                    .disabled(index == 0)
                widgetButton("chevron.down", title: "menu.widgets.down") { moveWidget(at: index, by: 1) }
                    .disabled(index == total - 1)
                widgetButton("minus.circle", title: "menu.widgets.remove") {
                    if expandedMenuWidget == widget.id { expandedMenuWidget = nil }
                    model.send(.menuWidgets(model.values.menuWidgets.filter { $0.id != widget.id }))
                }
            }
            .padding(.horizontal, 16)
            if isExpanded {
                widgetOptions(widget)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
    }

    private func widgetLayoutPreview(_ widgets: [MenuWidget]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SettingsDetail("menu.widgets.reorder")
            ForEach(MenuWidget.rows(for: widgets), id: \.first?.id) { row in
                HStack(spacing: 6) {
                    ForEach(row) { widget in
                        HStack(spacing: 5) {
                            Label(widget.kind == .history ? widget.displayMetric.title : widget.kind.title,
                                  systemImage: widget.kind.symbol)
                            if widget.kind == .heatmap { heatmapSwatch(widget) }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 30)
                        .background(widgetDropTarget == widget.id ? Color.accentColor.opacity(0.20) : .primary.opacity(0.055),
                                    in: RoundedRectangle(cornerRadius: 7))
                        .draggable(widgetDragScope + widget.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            widgetDropTarget = nil
                            guard let item = items.first, item.hasPrefix(widgetDragScope),
                                  let id = UUID(uuidString: String(item.dropFirst(widgetDragScope.count))) else { return false }
                            return moveWidget(id, onto: widget.id)
                        } isTargeted: { targeted in
                            if targeted { widgetDropTarget = widget.id }
                            else if widgetDropTarget == widget.id { widgetDropTarget = nil }
                        }
                    }
                    if row.count == 1, row[0].usesHalfWidth {
                        Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                    }
                }
            }
        }
        .padding(16)
    }

    private func heatmapSwatch(_ widget: MenuWidget) -> some View {
        Circle()
            .fill(Color(nsColor: widget.heatmapTheme.pickerColor))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private func widgetButton(_ symbol: String, title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 24)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(title))
        .help(title)
    }

    private func moveWidget(at index: Int, by offset: Int) {
        let widgets = model.values.menuWidgets
        guard widgets.indices.contains(index), widgets.indices.contains(index + offset) else { return }
        _ = moveWidget(widgets[index].id, onto: widgets[index + offset].id)
    }

    @discardableResult
    private func moveWidget(_ id: UUID, onto target: UUID) -> Bool {
        var widgets = model.values.menuWidgets
        guard id != target, let source = widgets.firstIndex(where: { $0.id == id }),
              let destination = widgets.firstIndex(where: { $0.id == target }) else { return false }
        let widget = widgets.remove(at: source)
        widgets.insert(widget, at: destination)
        model.send(.menuWidgets(widgets))
        return true
    }

    @ViewBuilder private func widgetOptions(_ widget: MenuWidget) -> some View {
        if widget.kind == .heatmap {
            heatmapSettings(widget)
        } else {
            VStack(spacing: 0) {
                if widget.kind.supportsHalfWidth {
                    SettingsRow("menu.widgets.width", controlHasLabel: true, compact: true) {
                        Picker("menu.widgets.width", selection: widgetBinding(widget, \.width)) {
                            ForEach(MenuWidget.Width.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden()
                    }
                }
                SettingsRow("menu.widgets.style", controlHasLabel: true, compact: true) {
                    Picker("menu.widgets.style", selection: widgetBinding(widget, \.style)) {
                        ForEach(MenuWidget.Style.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden()
                }
                if widget.kind.supportsDateRange {
                    SettingsRow("popover.historyRange", controlHasLabel: true, compact: true) {
                        Picker("popover.historyRange", selection: widgetBinding(widget, \.monthly)) {
                            Text("history.range.week").tag(false)
                            Text("history.range.month").tag(true)
                        }.labelsHidden()
                    }
                }
                if !widget.kind.metrics.isEmpty {
                    SettingsRow("popover.historyMetric", controlHasLabel: true, compact: true) {
                        Picker("popover.historyMetric", selection: widgetBinding(widget, \.metric)) {
                            ForEach(widget.kind.metrics, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden()
                    }
                }
                if widget.kind == .history {
                    SettingsRow("popover.chartStyle", controlHasLabel: true, compact: true) {
                        Picker("popover.chartStyle", selection: widgetBinding(widget, \.bars)) {
                            Text("history.chart.line").tag(false)
                            Text("history.chart.bar").tag(true)
                        }.labelsHidden()
                    }
                }
            }
        }
    }

    private func widgetBinding<Value>(_ widget: MenuWidget, _ keyPath: WritableKeyPath<MenuWidget, Value>) -> Binding<Value> {
        Binding(get: {
            (model.values.menuWidgets.first { $0.id == widget.id } ?? widget)[keyPath: keyPath]
        }, set: { value in
            var widgets = model.values.menuWidgets
            guard let index = widgets.firstIndex(where: { $0.id == widget.id }) else { return }
            widgets[index][keyPath: keyPath] = value
            model.send(.menuWidgets(widgets))
        })
    }

    private func heatmapSettings(_ widget: MenuWidget) -> some View {
        let theme = widgetBinding(widget, \.heatmapTheme)
        let effect = widgetBinding(widget, \.heatmapEffect)
        return VStack(spacing: 0) {
            SettingsRow("menuHeatmap.theme", compact: true) {
                HStack(spacing: 9) {
                    Menu("menuHeatmap.presets") {
                        Button("menuHeatmap.theme.green") { theme.wrappedValue = .green }
                        Button("menuHeatmap.theme.blue") { theme.wrappedValue = .blue }
                        Button("menuHeatmap.theme.purple") { theme.wrappedValue = .purple }
                        Button("menuHeatmap.theme.amber") { theme.wrappedValue = .amber }
                    }
                    ColorPicker("menuHeatmap.customColor", selection: Binding(
                        get: { Color(nsColor: theme.wrappedValue.pickerColor) },
                        set: { theme.wrappedValue = KeyboardHeatmapTheme(color: NSColor($0)) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityLabel("menuHeatmap.customColor")
                }
            }
            SettingsRow("menuHeatmap.effect", help: effect.wrappedValue == .still ? nil : "menuHeatmap.effect.help",
                        controlHasLabel: true, compact: true) {
                Picker("menuHeatmap.effect", selection: effect) {
                    ForEach(KeyboardHeatmapEffect.allCases, id: \.self) { effect in
                        Text(effect.title).tag(effect)
                    }
                }
                .labelsHidden()
            }
        }
    }

    @ViewBuilder private var notifications: some View {
        SettingsSection("settings.section.alerts") {
            switchRow("setting.notificationsEnabled", isOn: binding(\.notifications, action: SettingsAction.notifications))
        }
        if model.values.notifications {
            SettingsSection("settings.section.thresholds") {
                threshold("setting.notifyKeyThreshold", field: .keyPress)
                SettingsRule(inset: 16)
                threshold("setting.notifyClickThreshold", field: .click)
            }
        }
    }

    @ViewBuilder private var data: some View {
        SettingsSection("settings.section.statistics") {
            SettingsRow("settings.data.calibration", help: "settings.data.calibrationHelp") {
                Button("settings.data.calibrateAction") { model.send(.calibrate) }
                    .accessibilityLabel("settings.mouseDistanceCalibration")
            }
            SettingsRule(inset: 16)
            SettingsRow("settings.data.transfer", help: "settings.data.transferHelp") {
                HStack(spacing: 8) {
                    Button(model.values.transfer == .importing ? "import.inProgress" : "button.importData") {
                        model.send(.importData)
                    }
                    Button(model.values.transfer == .exporting ? "export.inProgress" : "button.exportData") {
                        model.send(.exportData)
                    }
                }
                .disabled(model.values.transfer != nil)
            }
        }
        SettingsSection("replay.recording.title") {
            switchRow("replay.recording.enable", help: "replay.recording.help", status: model.values.replayStatus,
                      isOn: binding(\.replay, action: SettingsAction.replay))
                .disabled(!model.values.replayAvailable)
            SettingsRule(inset: 16)
            SettingsRow("settings.data.savedRecordings") {
                Button("settings.data.deleteAction", role: .destructive) { model.send(.deleteReplay) }
                    .foregroundStyle(.red)
                    .accessibilityLabel("replay.recording.delete")
            }
        }
        SettingsSection("trackpad.title") {
            switchRow("trackpad.record.always", help: "trackpad.record.help", status: model.values.trackpadStatus,
                      isOn: binding(\.trackpad, action: SettingsAction.trackpad))
                .disabled(!model.values.trackpadAvailable)
            SettingsRule(inset: 16)
            SettingsRow("settings.data.savedRecordings") {
                Button("settings.data.deleteAction", role: .destructive) { model.send(.deleteTrackpad) }
                    .foregroundStyle(model.values.trackpadAvailable ? Color.red : .secondary)
                    .accessibilityLabel("trackpad.delete")
                    .disabled(!model.values.trackpadAvailable)
            }
        }
        SettingsSection("settings.section.reset") {
            SettingsRow("settings.data.today", help: "settings.data.resetHelp") {
                Button("button.reset", role: .destructive) { model.send(.reset) }
                    .foregroundStyle(model.values.transfer == nil ? Color.red : .secondary)
                    .disabled(model.values.transfer != nil)
            }
        }
    }

    private func selectPage(_ page: SettingsPage) {
        focusedPage = page
        model.selectPage(page)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let pages = SettingsPage.allCases
        guard let index = pages.firstIndex(of: focusedPage ?? model.page) else { return }
        switch direction {
        case .up: selectPage(pages[max(pages.startIndex, index - 1)])
        case .down: selectPage(pages[min(pages.count - 1, index + 1)])
        default: break
        }
    }

    private func binding<Value>(_ keyPath: KeyPath<SettingsModel.Values, Value>,
                                action: @escaping (Value) -> SettingsAction) -> Binding<Value> {
        Binding(get: { model.values[keyPath: keyPath] }, set: { model.send(action($0)) })
    }

    private func threshold(_ title: LocalizedStringKey, field: SettingsThreshold) -> some View {
        SettingsThresholdRow(title: title, draft: $model[dynamicMember: field.draft]) {
            model.send(.threshold(field))
        } step: { delta in
            model.send(.stepThreshold(field, delta))
        }
    }

    private func switchRow(_ title: LocalizedStringKey, help: LocalizedStringKey? = nil,
                           status: String? = nil, isOn: Binding<Bool>) -> some View {
        SettingsRow(title, help: help, status: status.map { LocalizedStringKey($0) }, controlHasLabel: true) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private static let version: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
        return "v\(version) (\(build))"
    }()

    private static let githubIcon: NSImage? = {
        let svg = """
        <svg aria-hidden="true" focusable="false" class="octicon octicon-mark-github" viewBox="0 0 24 24" width="32" height="32" fill="currentColor" display="inline-block" overflow="visible" style="vertical-align:text-bottom" xmlns="http://www.w3.org/2000/svg">
          <path d="M12 1C5.923 1 1 5.923 1 12c0 4.867 3.149 8.979 7.521 10.436.55.096.756-.233.756-.522 0-.262-.013-1.128-.013-2.049-2.764.509-3.479-.674-3.699-1.292-.124-.317-.66-1.293-1.127-1.554-.385-.207-.936-.715-.014-.729.866-.014 1.485.797 1.691 1.128.99 1.663 2.571 1.196 3.204.907.096-.715.385-1.196.701-1.471-2.448-.275-5.005-1.224-5.005-5.432 0-1.196.426-2.186 1.128-2.956-.111-.275-.496-1.402.11-2.915 0 0 .921-.288 3.024 1.128a10.193 10.193 0 0 1 2.75-.371c.936 0 1.871.123 2.75.371 2.104-1.43 3.025-1.128 3.025-1.128.605 1.513.221 2.64.111 2.915.701.77 1.127 1.747 1.127 2.956 0 4.222-2.571 5.157-5.019 5.432.399.344.743 1.004.743 2.035 0 1.471-.014 2.654-.014 3.025 0 .289.206.632.756.522C19.851 20.979 23 16.854 23 12c0-6.077-4.922-11-11-11Z"></path>
        </svg>
        """
        guard let data = svg.data(using: .utf8) else { return nil }
        let image = NSImage(data: data)
        image?.isTemplate = true
        return image
    }()
}

private struct SettingsAppIconClickTarget: NSViewRepresentable {
    let activate: () -> Void

    func makeNSView(context: Context) -> ClickView { ClickView() }

    func updateNSView(_ view: ClickView, context: Context) { view.activate = activate }

    final class ClickView: NSView {
        var activate: (() -> Void)?
        private var clicks = 0
        private var lastClick = -Double.infinity

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {}

        override func mouseUp(with event: NSEvent) {
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else {
                clicks = 0
                return
            }
            if event.timestamp - lastClick > NSEvent.doubleClickInterval { clicks = 0 }
            lastClick = event.timestamp
            clicks += 1
            if clicks == 5 {
                clicks = 0
                activate?()
            }
        }
    }
}

private struct SettingsSidebarFocusEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) { content.focusEffectDisabled() }
        else { content }
    }
}

private struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    let help: LocalizedStringKey?
    let status: LocalizedStringKey?
    let controlHasLabel: Bool
    let compact: Bool
    let control: Control

    init(_ title: LocalizedStringKey, help: LocalizedStringKey? = nil, status: LocalizedStringKey? = nil,
         controlHasLabel: Bool = false, compact: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = title
        self.help = help
        self.status = status
        self.controlHasLabel = controlHasLabel
        self.compact = compact
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 18) {
                Text(title)
                    .font(.system(size: compact ? 12 : 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(controlHasLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                control.fixedSize(horizontal: true, vertical: false)
            }
            if let help { SettingsDetail(help) }
            if let status { SettingsDetail(status, size: 11) }
        }
        .padding(.horizontal, compact ? 12 : 16)
        .padding(.vertical, compact ? 5 : 11)
        .frame(minHeight: compact ? 34 : 46)
    }
}

private struct SettingsSection<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: LocalizedStringKey
    let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 2)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var surface: Color {
        colorScheme == .dark ? Color.primary.opacity(0.065) : Color(nsColor: .controlBackgroundColor)
    }
}

private struct SettingsDetail: View {
    let title: LocalizedStringKey
    let size: CGFloat

    init(_ title: LocalizedStringKey, size: CGFloat = 12) {
        self.title = title
        self.size = size
    }

    var body: some View {
        Text(title)
            .font(.system(size: size))
            .foregroundStyle(.secondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsRule: View {
    var inset: CGFloat = 0

    var body: some View {
        Divider().opacity(0.64).padding(.horizontal, inset)
    }
}

private struct SettingsWidgetTileStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered || configuration.isPressed
                          ? Color.accentColor.opacity(configuration.isPressed ? 0.18 : 0.10)
                          : Color.primary.opacity(0.055))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct SettingsThresholdRow: View {
    let title: LocalizedStringKey
    @Binding var draft: String
    let commit: () -> Void
    let step: (Int) -> Void
    @FocusState private var editing: Bool

    var body: some View {
        SettingsRow(title, controlHasLabel: true) {
            HStack(spacing: 8) {
                TextField(title, text: $draft)
                    .labelsHidden()
                    .accessibilityLabel(Text(title))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .focused($editing)
                    .onSubmit(commit)
                    .onChange(of: editing) { editing in
                        if !editing { commit() }
                    }
                SettingsDetail("setting.notifyUnit")
                Stepper { step(100) } onDecrement: { step(-100) } label: { Text(title) }
                    .labelsHidden()
                    .accessibilityValue(Text(verbatim: draft))
            }
            .controlSize(.small)
        }
    }
}

/// The preview uses the status item's original renderer so the numbers match the menu bar.
private struct SettingsMenuBarPreview: NSViewRepresentable {
    var fullNumbers: Bool

    func makeNSView(context: Context) -> MenuBarStatusView {
        let view = MenuBarStatusView()
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel(NSLocalizedString("settings.menuDisplay.preview", comment: ""))
        return view
    }

    func updateNSView(_ view: MenuBarStatusView, context: Context) {
        view.update(.init(
            keysText: MenuBarDisplayPreferences.number(12856, full: fullNumbers),
            clicksText: MenuBarDisplayPreferences.number(3210, full: fullNumbers),
            fullNumbers: fullNumbers
        ))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuBarStatusView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            preview(.general).preferredColorScheme(.light).previewDisplayName("General")
            preview(.appearance).preferredColorScheme(.light).previewDisplayName("Appearance")
            preview(.notifications).preferredColorScheme(.dark).previewDisplayName("Notifications")
            preview(.data).preferredColorScheme(.dark).previewDisplayName("Data")
        }
    }

    private static func preview(_ page: SettingsPage) -> some View {
        let model = SettingsModel(page: page)
        model.values.trackApps = true
        model.values.notifications = true
        model.keyThreshold = "1000"
        return SettingsView(model: model).frame(width: 840, height: 620)
    }
}
#endif
