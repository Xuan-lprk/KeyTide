import Foundation

enum HelperLocations {
    static let mainBundleId = "com.xuanlprk.KeyTide"
    static let helperBundleId = "com.xuanlprk.KeyTide.helper"
    static let machServiceName = "com.xuanlprk.KeyTide.helper"
    static let launchAgentLabel = "com.xuanlprk.KeyTide.helper"
    static let interfaceVersion = 4
    static let trackpadControlVersion = 3
    static let inputOwnershipVersion = 4

    static var installDir: URL {
        let base = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("Keytide/Helper", isDirectory: true)
    }

    static var installedHelperURL: URL {
        installDir.appendingPathComponent("KeytideHelper.app", isDirectory: true)
    }

    static var installedHelperBinaryURL: URL {
        installedHelperURL.appendingPathComponent("Contents/MacOS/KeytideHelper")
    }

    static var launchAgentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    static var trackpadBackgroundMarker: URL {
        installDir.appendingPathComponent("TrackpadRecordingEnabled.v1")
    }

    static var inputBackgroundMarker: URL {
        installDir.appendingPathComponent("BackgroundInputAllowed.v1")
    }
}
