import Foundation

enum HelperLocations {
    #if DEBUG
    static let isDevelopment = true
    static let mainBundleId = "com.xuanlprk.KeyTide.debug"
    private static let supportFolder = "Keytide Debug"
    #else
    static let isDevelopment = false
    static let mainBundleId = "com.xuanlprk.KeyTide"
    private static let supportFolder = "Keytide"
    #endif

    static let helperBundleId = mainBundleId + ".helper"
    static let machServiceName = helperBundleId
    static let launchAgentLabel = helperBundleId
    static let interfaceVersion = 4
    static let trackpadControlVersion = 3
    static let inputOwnershipVersion = 4

    static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(supportFolder, isDirectory: true)
    }

    static var installDir: URL {
        applicationSupportDirectory.appendingPathComponent("Helper", isDirectory: true)
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
