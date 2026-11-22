import Foundation
import Security
import AppKit

final class HelperXPCListener: NSObject, NSXPCListenerDelegate, KeytideHelperProtocol, EventPayloadSink {
    private let listener: NSXPCListener
    private let idle = HelperIdleSupervisor()
    private let tap = EventTapController()
    private let trackpad = HelperTrackpadService()
    private lazy var input = HelperInputService(tap: tap, defaults: UserDefaults(suiteName: HelperLocations.mainBundleId)!) {
        [weak self] metric, count, threshold in
        self?.captureProxy()?.receiveThresholdNotification?(metric == .keyPresses, count: count, threshold: threshold)
    }
    private weak var trackpadClient: NSXPCConnection?
    private weak var captureClient: NSXPCConnection?
    private let stateLock = NSLock()
    private var activeConnection: NSXPCConnection?
    private var activeClientVersion: Int?

    override init() {
        self.listener = NSXPCListener(machServiceName: HelperLocations.machServiceName)
        super.init()
        self.listener.delegate = self

        // macOS 13+ only (deployment target is 13.0).
        let req = "identifier \"\(HelperLocations.mainBundleId)\""
        self.listener.setConnectionCodeSigningRequirement(req)
    }

    func resume() {
        // A v3 trackpad marker is not consent to keep all input capture running.
        try? FileManager.default.removeItem(at: HelperLocations.trackpadBackgroundMarker)
        trackpad.sendPreview = { [weak self] data in self?.trackpadProxy()?.receiveTrackpadPreview?(data) }
        trackpad.sendStatus = { [weak self] status in self?.trackpadProxy()?.receiveTrackpadStatus?(status.rawValue) }
        trackpad.restore()
        input.sink = self
        input.onKeepAlive = { [weak self] active in self?.idle.setBackgroundWorkActive(active) }
        input.onPresenceChange = { [weak self] connected, detached in
            self?.trackpad.updatePresence(connected: connected, allowsDetached: detached)
        }
        input.onSnapshot = { [weak self] data in self?.captureProxy()?.receiveInputSnapshot?(data) }
        input.onReplayStatus = { [weak self] status in self?.captureProxy()?.receiveKeyboardReplayStatus?(status.rawValue) }
        input.restore()
        listener.resume()
    }

    func finish() { input.finish(); trackpad.finish() }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard validatePeer(newConnection) else {
            NSLog("[KeytideHelper] peer validation failed, rejecting pid=\(newConnection.processIdentifier)")
            return false
        }

        stateLock.lock()
        if activeConnection != nil {
            stateLock.unlock()
            NSLog("[KeytideHelper] active connection exists, rejecting new")
            return false
        }
        // Reserve the slot until the authenticated connection is fully installed.
        activeConnection = newConnection
        activeClientVersion = nil
        stateLock.unlock()

        newConnection.exportedInterface = NSXPCInterface(with: KeytideHelperProtocol.self)
        newConnection.exportedObject = self

        let remote = NSXPCInterface(with: KeytideEventSinkProtocol.self)
        let classes = NSSet(array: [NSDictionary.self, NSString.self, NSNumber.self]) as! Set<AnyHashable>
        remote.setClasses(
            classes,
            for: #selector(KeytideEventSinkProtocol.receiveEvent(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        newConnection.remoteObjectInterface = remote

        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            self?.handleConnectionClosed(newConnection)
        }
        newConnection.interruptionHandler = { [weak self, weak newConnection] in
            self?.handleConnectionClosed(newConnection)
        }

        idle.connectionDidOpen()
        newConnection.resume()
        NSLog("[KeytideHelper] accepted connection from pid=\(newConnection.processIdentifier)")
        return true
    }

    private func validatePeer(_ conn: NSXPCConnection) -> Bool {
        let pid = conn.processIdentifier
        guard pid > 0 else { return false }

        var code: SecCode?
        let attrs: [String: Any] = [kSecGuestAttributePid as String: Int(pid)]
        var status = SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &code)
        guard status == errSecSuccess, let code = code else { return false }

        status = SecCodeCheckValidity(code, [], nil)
        guard status == errSecSuccess else { return false }

        var info: CFDictionary?
        status = SecCodeCopySigningInformation(
            code as! SecStaticCode,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &info
        )
        guard status == errSecSuccess, let d = info as? [String: Any] else { return false }

        guard let identifier = d[kSecCodeInfoIdentifier as String] as? String,
              identifier == HelperLocations.mainBundleId else {
            return false
        }

        let uid = conn.effectiveUserIdentifier
        guard uid == getuid() else { return false }

        return true
    }

    private func handleConnectionClosed(_ conn: NSXPCConnection?) {
        stateLock.lock()
        guard let conn, activeConnection === conn else {
            stateLock.unlock()
            return
        }
        activeConnection = nil
        activeClientVersion = nil
        // Enqueue the close before a replacement can enqueue its open.
        idle.connectionDidClose()
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.captureClient === conn {
                self.captureClient = nil
                self.input.detach()
            }
            if self.trackpadClient === conn {
                self.trackpadClient = nil
                self.trackpad.detachPreview()
            }
        }
    }

    func handshake(clientInterfaceVersion: Int,
                   reply: @escaping (Int, Bool) -> Void) {
        idle.noteActivity()
        if let connection = NSXPCConnection.current() {
            stateLock.lock()
            if activeConnection === connection { activeClientVersion = clientInterfaceVersion }
            stateLock.unlock()
        }
        if tap.isAccessibilityGranted() {
            reply(HelperLocations.interfaceVersion, true)
            return
        }
        // AXIsProcessTrusted() 在 helper 进程刚被 launchd spawn 出来时
        // 偶尔会先返回 false（TCC 还没把当前 PID 跟 helper 的 cdhash 关联好）。
        // 100ms / 400ms / 1000ms 后逐级重查，最多 ~1.5s 内若有任何一次返回
        // true 就立刻返回，否则才报"未授权"。
        Self.recheckAccessibility(tap: tap, delays: [0.1, 0.4, 1.0]) { granted in
            reply(HelperLocations.interfaceVersion, granted)
        }
    }

    private static func recheckAccessibility(
        tap: EventTapController,
        delays: [TimeInterval],
        completion: @escaping (Bool) -> Void
    ) {
        guard let next = delays.first else {
            completion(false)
            return
        }
        let rest = Array(delays.dropFirst())
        DispatchQueue.global().asyncAfter(deadline: .now() + next) {
            if tap.isAccessibilityGranted() {
                completion(true)
            } else {
                recheckAccessibility(tap: tap, delays: rest, completion: completion)
            }
        }
    }

    func startMonitoring(reply: @escaping (Bool, Int) -> Void) {
        guard let connection = NSXPCConnection.current() else { reply(false, HelperErrorCode.tapCreateFailed); return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCompatible(connection) else { reply(false, HelperErrorCode.incompatibleClient); return }
            self.attachPresentation(connection)
            let code = self.input.attach()
            reply(code == HelperErrorCode.none || code == HelperErrorCode.alreadyMonitoring, code)
        }
    }

    func stopMonitoring() {
        guard let connection = NSXPCConnection.current() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.captureClient === connection else { return }
            self.captureClient = nil
            self.input.detach()
        }
    }

    func setReplayRecordingEnabled(_ enabled: Bool, reply: @escaping (Bool) -> Void) {
        // A version 2/3 client must not change the local v4 writer's replay consent.
        reply(false)
    }

    func controlInput(_ command: Int, argument: Data, reply: @escaping (Data?, Bool) -> Void) {
        guard let action = InputControl(rawValue: command), let connection = NSXPCConnection.current() else {
            reply(nil, false); return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCompatible(connection) else { reply(nil, false); return }
            self.attachPresentation(connection)
            self.input.control(action, argument: argument, reply: reply)
        }
    }

    func promptAccessibility(reply: @escaping (Bool) -> Void) {
        idle.noteActivity()
        reply(tap.promptAccessibilityTrust())
    }

    func helperBundleURL(reply: @escaping (String) -> Void) {
        reply(Bundle.main.bundleURL.path)
    }

    func controlTrackpad(_ command: Int, reply: @escaping (Int, Bool) -> Void) {
        guard let action = TrackpadControl(rawValue: command), let connection = NSXPCConnection.current() else {
            reply(TrackpadRecordingStatus.off.rawValue, false)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCompatible(connection) else {
                reply(TrackpadRecordingStatus.off.rawValue, false)
                return
            }
            if let previous = self.trackpadClient, previous !== connection {
                self.trackpad.detachPreview()
            }
            self.attachPresentation(connection)
            self.trackpadClient = connection
            self.trackpad.control(action, reply: reply)
        }
    }

    private func isActive(_ connection: NSXPCConnection) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return activeConnection === connection
    }

    private func isCompatible(_ connection: NSXPCConnection) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return activeConnection === connection && (activeClientVersion ?? 0) >= HelperLocations.inputOwnershipVersion
    }

    private func attachPresentation(_ connection: NSXPCConnection) {
        if captureClient === connection { return }
        if captureClient != nil { input.detach() }
        captureClient = connection
        input.attachForPresentation()
    }

    private func trackpadProxy() -> KeytideEventSinkProtocol? {
        guard let client = trackpadClient, isActive(client) else { return nil }
        return client.remoteObjectProxyWithErrorHandler { _ in } as? KeytideEventSinkProtocol
    }

    private func captureProxy() -> KeytideEventSinkProtocol? {
        guard let client = captureClient, isActive(client) else { return nil }
        return client.remoteObjectProxyWithErrorHandler { _ in } as? KeytideEventSinkProtocol
    }

    func forward(payload: [String: Any]) { input.receive(payload) }
}
