import Cocoa

enum MenuUIStyle: String, CaseIterable {
    case standard
    case geek

    static let defaultsKey = "menuUIStyle.v1"
    static var current: MenuUIStyle {
        MenuUIStyle(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .standard
    }
}

extension Notification.Name {
    static let menuUIStyleDidChange = Notification.Name("Keytide.menuUIStyleDidChange")
}

protocol MenuStatsPresenting: AnyObject {
    var preferredSizeDidChange: ((NSSize) -> Void)? { get set }
    var preferredContentSize: NSSize { get }
    var historySelection: MenuHistorySelection { get set }
    func prepareForPopoverPresentation()
}

struct MenuHistorySelection {
    var range = 0
    var metric = 0
    var chartStyle = 0
}

extension StatsPopoverViewController: MenuStatsPresenting {}
extension GeekStatsPopoverViewController: MenuStatsPresenting {}
