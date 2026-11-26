import Foundation
import Security

/// - 从主 app Resources 里找 KeytideHelper.app 并拷到 Application Support
/// - 按 cdhash 判断是否需要覆盖（cdhash 稳定 ⇒ TCC 授权跨升级保留的前提）
/// - 写入 LaunchAgent plist 并 bootstrap
final class HelperSupervisor {
    static let shared = HelperSupervisor()
    private let registrationLock = NSLock()
    private init() {}

    enum SupervisorError: Error {
        case missingBundledHelper
        case unexpectedBundleIdentity
        case copyFailed(Error)
        case plistWriteFailed(Error)
        case launchctlFailed(Int32, String)
        case cdhashUnavailable(OSStatus)
    }

    func ensureInstalled() throws {
        registrationLock.lock()
        defer { registrationLock.unlock() }
        let fm = FileManager.default

        let bundledHelper = try checkedBundledHelper()
        try fm.createDirectory(at: HelperLocations.installDir, withIntermediateDirectories: true)

        let target = HelperLocations.installedHelperURL

        let shouldCopy: Bool = {
            guard fm.fileExists(atPath: target.path) else { return true }
            // 关键：用 cdhash 判定，保持 TCC 授权稳定。文件系统上随便碰到的
            // mtime 变化（rsync、备份还原）不应触发重装。
            guard let bundledHash = try? readCDHash(at: bundledHelper),
                  let installedHash = try? readCDHash(at: target) else {
                return true
            }
            return bundledHash != installedHash
        }()

        if shouldCopy {
            do {
                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }
                try fm.copyItem(at: bundledHelper, to: target)
                stripQuarantine(at: target)
            } catch {
                throw SupervisorError.copyFailed(error)
            }
        }

        // Prepare all files before disturbing the old running service.
        let previousNewData = try? Data(contentsOf: HelperLocations.launchAgentPlistURL)
        let changed = try writeLaunchAgentPlist()
        let home = fm.homeDirectoryForCurrentUser
        let legacy = try installedLegacyAgent(home: home)
        let transaction = HelperServiceSwitch(fileManager: fm, unload: { label in
            try self.unloadLaunchAgent(label: label)
        }, load: { url in
            let result = self.runLaunchctl(["bootstrap", "gui/\(getuid())", url.path])
            guard result.status == 0 else { throw SupervisorError.launchctlFailed(result.status, result.stderr) }
        })
        try transaction.perform(legacy: legacy, newURL: HelperLocations.launchAgentPlistURL,
                                newLabel: HelperLocations.launchAgentLabel, previousNewData: previousNewData) {
            if shouldCopy || changed || !self.isLaunchAgentLoaded() {
                try self.bootstrapLaunchAgent(restartExisting: shouldCopy || changed)
            }
        }
    }

    /// Restore a missing registration using the files prepared by normal startup.
    func restoreRegistrationIfMissing() throws {
        registrationLock.lock()
        defer { registrationLock.unlock() }
        guard !isLaunchAgentLoaded() else { return }
        let url = HelperLocations.launchAgentPlistURL
        guard let data = try? Data(contentsOf: url),
              matchesLaunchAgentConfiguration(data),
              let bundledHelper = try? checkedBundledHelper(),
              let bundledHash = try? readCDHash(at: bundledHelper),
              (try? readCDHash(at: HelperLocations.installedHelperURL)) == bundledHash,
              try installedLegacyAgent(home: FileManager.default.homeDirectoryForCurrentUser)?.wasLoaded != true
        else { return }
        try bootstrapLaunchAgent(restartExisting: false)
    }

    // MARK: - LaunchAgent

    private var launchAgentConfiguration: [String: Any] {
        [
            "Label": HelperLocations.launchAgentLabel,
            "ProgramArguments": [HelperLocations.installedHelperBinaryURL.path],
            "MachServices": [HelperLocations.machServiceName: true],
            "KeepAlive": ["PathState": [HelperLocations.inputBackgroundMarker.path: true]],
            "LimitLoadToSessionType": ["Aqua"],
            "ProcessType": "Interactive"
        ]
    }

    private func matchesLaunchAgentConfiguration(_ data: Data) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary else { return false }
        return plist.isEqual(launchAgentConfiguration as NSDictionary)
    }

    @discardableResult
    private func writeLaunchAgentPlist() throws -> Bool {
        do {
            let url = HelperLocations.launchAgentPlistURL
            if let existingData = try? Data(contentsOf: url), matchesLaunchAgentConfiguration(existingData) {
                return false
            }
            let data = try PropertyListSerialization.data(fromPropertyList: launchAgentConfiguration, format: .xml, options: 0)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            throw SupervisorError.plistWriteFailed(error)
        }
    }

    private func bootstrapLaunchAgent(restartExisting: Bool) throws {
        if restartExisting {
            try unloadLaunchAgent(label: HelperLocations.launchAgentLabel)
        }
        let res = runLaunchctl(["bootstrap", "gui/\(getuid())", HelperLocations.launchAgentPlistURL.path])
        if res.status != 0 {
            if isLaunchAgentLoaded() {
                return
            }
            throw SupervisorError.launchctlFailed(res.status, res.stderr)
        }
    }

    private func isLaunchAgentLoaded(label: String = HelperLocations.launchAgentLabel) -> Bool {
        runLaunchctl(["print", "gui/\(getuid())/\(label)"]).status == 0
    }

    private func unloadLaunchAgent(label: String) throws {
        try HelperServiceSwitch.stopIfLoaded(
            isLoaded: { self.isLaunchAgentLoaded(label: label) },
            stop: {
                let result = self.runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
                guard result.status == 0 else { throw SupervisorError.launchctlFailed(result.status, result.stderr) }
            },
            pause: { Thread.sleep(forTimeInterval: 0.1) }
        )
    }

    private func installedLegacyAgent(home: URL) throws -> HelperServiceSwitch.Legacy? {
        guard !HelperLocations.isDevelopment else { return nil }
        let url = home.appendingPathComponent("Library/LaunchAgents/com.xuanlprk.KeyStatsMac.helper.plist")
        return try HelperServiceSwitch.matchingLegacy(at: url, home: home) { self.isLaunchAgentLoaded(label: $0) }
    }

    // MARK: - Helpers

    private func checkedBundledHelper() throws -> URL {
        guard let url = bundledHelperURL() else { throw SupervisorError.missingBundledHelper }
        guard Bundle.main.bundleIdentifier == HelperLocations.mainBundleId,
              Bundle(url: url)?.bundleIdentifier == HelperLocations.helperBundleId else {
            throw SupervisorError.unexpectedBundleIdentity
        }
        return url
    }

    private func bundledHelperURL() -> URL? {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/KeytideHelper.app"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/KeytideHelper.app"),
        ]
        for c in candidates where fm.fileExists(atPath: c.path) {
            return c
        }
        return nil
    }

    /// 读 .app bundle 的 CDHash，返回 hex 字符串（对应 codesign -dvvv 的 CDHash）。
    private func readCDHash(at url: URL) throws -> String {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode = staticCode else {
            throw SupervisorError.cdhashUnavailable(createStatus)
        }
        var info: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &info
        )
        guard infoStatus == errSecSuccess,
              let d = info as? [String: Any],
              let hashes = d["cdhashes"] as? [Data],
              let primary = hashes.first else {
            throw SupervisorError.cdhashUnavailable(infoStatus)
        }
        return primary.map { String(format: "%02x", $0) }.joined()
    }

    private func stripQuarantine(at url: URL) {
        let p = Process()
        p.launchPath = "/usr/bin/xattr"
        p.arguments = ["-rd", "com.apple.quarantine", url.path]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
    }

    private func runLaunchctl(_ args: [String]) -> (status: Int32, stderr: String) {
        let p = Process()
        p.launchPath = "/bin/launchctl"
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch {
            return (-1, "\(error)")
        }
        p.waitUntilExit()
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, stderr)
    }
}
