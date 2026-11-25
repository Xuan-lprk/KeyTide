import Cocoa

enum MenuPresentation: String, CaseIterable {
    case widgets
    case classic = "standard"
    case geek

    private static let defaultsKey = "menu.presentation.v1"

    var title: String {
        NSLocalizedString("settings.menuPresentation." + (self == .classic ? "classic" : rawValue), comment: "")
    }

    var popoverStyle: MenuUIStyle? {
        switch self {
        case .widgets: return nil
        case .classic: return .standard
        case .geek: return .geek
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        let saved = defaults.string(forKey: defaultsKey)
        // The previous picker used the legacy style key to choose the classic renderer.
        if saved == "classic" {
            return defaults.string(forKey: MenuUIStyle.defaultsKey) == MenuUIStyle.geek.rawValue ? .geek : .classic
        }
        return saved.flatMap(Self.init(rawValue:)) ?? .widgets
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

enum MenuUIStyle: String, CaseIterable {
    case standard
    case geek
    case keyboardHeatmap

    var title: String {
        switch self {
        case .standard: return NSLocalizedString("settings.uiStyle.standard", comment: "")
        case .geek: return NSLocalizedString("settings.uiStyle.geek", comment: "")
        case .keyboardHeatmap: return NSLocalizedString("settings.uiStyle.keyboardHeatmap", comment: "")
        }
    }

    static let defaultsKey = "menuUIStyle.v1"
    static let defaultStyle: Self = .keyboardHeatmap
    static var current: MenuUIStyle {
        MenuUIStyle(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? defaultStyle
    }
}

extension Notification.Name {
    static let menuUIStyleDidChange = Notification.Name("Keytide.menuUIStyleDidChange")
}

struct MenuHistorySelection {
    var range = 0
    var metric = 0
    var chartStyle = 0
}

enum MenuWidgetKind: String, CaseIterable, Codable, Identifiable {
    case pulse, today, keys, history, mouse, heatmap
    case activity, calendar, apps, totals, peaks

    var id: Self { self }

    var supportsHalfWidth: Bool {
        switch self {
        case .heatmap, .keys, .calendar, .totals: return false
        default: return true
        }
    }

    var supportsDateRange: Bool { self == .history || self == .activity || self == .apps }

    var metrics: [MenuWidget.Metric] {
        switch self {
        case .history: return [.keys, .clicks, .movement, .scroll]
        case .calendar: return [.combined, .keys, .clicks]
        case .apps: return [.keys, .clicks, .scroll]
        default: return []
        }
    }

    var title: String {
        NSLocalizedString("menu.widgets." + rawValue, comment: "")
    }

    var symbol: String {
        switch self {
        case .pulse: return "waveform.path"
        case .today: return "number"
        case .keys: return "rectangle.grid.1x2"
        case .history: return "chart.xyaxis.line"
        case .mouse: return "computermouse"
        case .heatmap: return "keyboard"
        case .activity: return "chart.bar.xaxis"
        case .calendar: return "calendar"
        case .apps: return "square.grid.2x2"
        case .totals: return "sum"
        case .peaks: return "speedometer"
        }
    }
}

struct MenuWidget: Codable, Equatable, Identifiable {
    enum Style: String, CaseIterable, Codable {
        case standard, geek
        var title: String { NSLocalizedString("menu.widgets.style." + rawValue, comment: "") }
    }

    enum Metric: String, CaseIterable, Codable {
        case keys, clicks, movement, scroll, combined

        var title: String {
            let key: String
            switch self {
            case .keys: key = "stats.keyPresses"
            case .clicks: key = "stats.totalClicks"
            case .movement: key = "stats.mouseDistance"
            case .scroll: key = "stats.scrollDistance"
            case .combined: key = "heatmap.metric.combined"
            }
            return NSLocalizedString(key, comment: "")
        }
    }

    enum Width: String, CaseIterable, Codable {
        case half, full
        var title: String { NSLocalizedString("menu.widgets.width." + rawValue, comment: "") }
    }

    var id = UUID()
    let kind: MenuWidgetKind
    var style = Style.standard
    var width = Width.full
    var metric = Metric.keys
    var monthly = false
    var bars = false
    var heatmapThemeRGB = KeyboardHeatmapTheme.defaultTheme.rgb
    var heatmapEffect = KeyboardHeatmapEffect.still

    var heatmapTheme: KeyboardHeatmapTheme {
        get { KeyboardHeatmapTheme(rgb: heatmapThemeRGB) }
        set { heatmapThemeRGB = newValue.rgb }
    }

    var usesHalfWidth: Bool { kind.supportsHalfWidth && width == .half }

    var displayMetric: Metric { kind.metrics.contains(metric) ? metric : (kind.metrics.first ?? .keys) }

    static func rows(for widgets: [Self], allowsHalfWidth: Bool = true) -> [[Self]] {
        var rows: [[Self]] = []
        for widget in widgets {
            if allowsHalfWidth, widget.usesHalfWidth, let last = rows.indices.last,
               rows[last].count == 1, rows[last][0].usesHalfWidth {
                rows[last].append(widget)
            } else {
                rows.append([widget])
            }
        }
        return rows
    }
}

enum MenuWidgetPreferences {
    private static let key = "menu.widgets.v1"

    static func load(from defaults: UserDefaults = .standard) -> [MenuWidget] {
        if let stored = defaults.object(forKey: key) {
            guard let data = stored as? Data, let widgets = try? JSONDecoder().decode([MenuWidget].self, from: data) else { return [] }
            var seen = Set<UUID>()
            return widgets.filter { seen.insert($0.id).inserted }
        }

        // Only migrate a layout the user explicitly chose in the old picker.
        guard let saved = defaults.string(forKey: MenuUIStyle.defaultsKey), let style = MenuUIStyle(rawValue: saved) else { return [] }
        let widgets: [MenuWidget]
        switch style {
        case .keyboardHeatmap:
            widgets = [MenuWidget(kind: .heatmap, heatmapThemeRGB: KeyboardHeatmapTheme.legacyValue(in: defaults).rgb,
                                  heatmapEffect: KeyboardHeatmapEffect.legacyValue(in: defaults))]
        case .standard, .geek:
            let widgetStyle: MenuWidget.Style = style == .geek ? .geek : .standard
            widgets = [MenuWidgetKind.pulse, .today, .keys, .history, .mouse].map { MenuWidget(kind: $0, style: widgetStyle) }
        }
        save(widgets, to: defaults)
        return widgets
    }

    static func save(_ widgets: [MenuWidget], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(widgets) else { return }
        defaults.set(data, forKey: key)
    }
}
