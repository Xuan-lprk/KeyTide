import AppKit
import CoreGraphics

/// Helper-side event interpretation. The owner supplies its local statistics engine
/// and a separately consented replay sink.
final class InputEventAggregator {
    let stats: StatsManager
    var onReplay: (UInt64, UInt16, KeyReplayEvent.Phase, [String]) -> Void = { _, _, _, _ in }
    var onReplayGap: () -> Void = {}
    private let decoder = InputEventDecoder.shared
    private var modifierTracker = ModifierStandaloneTracker()
    private let modifierLock = NSLock()
    private var scrollSessionTracker = ScrollSessionTracker()
    private var activeScrollSessionAppIdentity: AppIdentity?
    private let scrollSessionLock = NSLock()

    init(stats: StatsManager) { self.stats = stats }

    func resetTransientInput() {
        modifierLock.lock(); modifierTracker.reset(); modifierLock.unlock()
        scrollSessionLock.lock()
        scrollSessionTracker = ScrollSessionTracker()
        activeScrollSessionAppIdentity = nil
        scrollSessionLock.unlock()
        stats.lastMousePosition = nil
    }

    func receiveEvent(_ payload: [String: Any]) {
        guard let typeRaw = (payload[HelperPayloadFields.type] as? NSNumber)?.uint32Value,
              let type = CGEventType(rawValue: typeRaw) else { return }

        let pid = (payload[HelperPayloadFields.sourcePID] as? NSNumber)?.int32Value ?? 0
        let stats = self.stats

        if type == SystemMediaKey.eventType {
            guard let baseName = SystemMediaKey.keyName(from: payload),
                  let flags = (payload[HelperPayloadFields.flags] as? NSNumber)?.uint64Value
            else { return }
            if stats.handleMouseDistanceCalibrationKeyPress() { return }
            // Use the existing modifier naming/consumption rules. No hardware F-key is inferred.
            modifierLock.lock()
            modifierTracker.consumePendingModifiers(forKeyDownWith: flags, keyCode: 0)
            modifierLock.unlock()
            let modifiers = keyboardEventModifierNames(rawFlags: flags, keyCode: 0)
            let name = (modifiers + [baseName]).joined(separator: "+")
            stats.incrementKeyPresses(keyName: name)
            return
        }

        switch type {
        case .keyDown:
            let isAutoRepeat = (payload[HelperPayloadFields.isAutoRepeat] as? NSNumber)?.boolValue ?? false
            if isAutoRepeat { return }
            if stats.handleMouseDistanceCalibrationKeyPress() { return }
            guard let keyCode = (payload[HelperPayloadFields.keyCode] as? NSNumber)?.intValue,
                  let keyboardType = (payload[HelperPayloadFields.keyboardType] as? NSNumber)?.uint32Value,
                  let flagsRaw = (payload[HelperPayloadFields.flags] as? NSNumber)?.uint64Value
            else { return }

            modifierLock.lock()
            modifierTracker.consumePendingModifiers(forKeyDownWith: flagsRaw, keyCode: keyCode)
            modifierLock.unlock()

            let name = decoder.keyName(keyCode: keyCode, keyboardType: keyboardType, flagsRaw: flagsRaw)
            stats.incrementKeyPresses(keyName: name, appIdentity: appIdentity(forPID: pid))
            recordReplay(payload, growthName: name)

        case .keyUp:
            recordReplay(payload)

        case .flagsChanged:
            guard let keyCode = (payload[HelperPayloadFields.keyCode] as? NSNumber)?.intValue,
                  let flagsRaw = (payload[HelperPayloadFields.flags] as? NSNumber)?.uint64Value
            else { return }

            if keyCode == 57 {  // CapsLock
                stats.incrementKeyPresses(keyName: "CapsLock", appIdentity: appIdentity(forPID: pid))
                recordReplay(payload, growthName: "CapsLock")
                return
            }

            modifierLock.lock()
            let modifierName = modifierTracker.handleFlagsChanged(keyCode: keyCode, rawFlags: flagsRaw)
            modifierLock.unlock()
            if let modifierName {
                stats.incrementKeyPresses(keyName: modifierName, appIdentity: appIdentity(forPID: pid))
            }
            recordReplay(payload, growthName: modifierName)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Older installed Helpers label every non-forward auxiliary button
            // as Back. The existing physical number distinguishes Middle.
            if type == .otherMouseDown,
               (payload[HelperPayloadFields.buttonNumber] as? NSNumber)?.intValue == 2 {
                stats.incrementMiddleClicks(appIdentity: appIdentity(forPID: pid))
                return
            }
            let role = payload[HelperPayloadFields.buttonRole] as? String
            let ident = appIdentity(forPID: pid)
            switch role {
            case ButtonRole.primary: stats.incrementLeftClicks(appIdentity: ident)
            case ButtonRole.secondary: stats.incrementRightClicks(appIdentity: ident)
            case ButtonRole.back: stats.incrementSideBackClicks(appIdentity: ident)
            case ButtonRole.forward: stats.incrementSideForwardClicks(appIdentity: ident)
            default: break
            }

        case .scrollWheel:
            let dx = (payload[HelperPayloadFields.scrollDX] as? NSNumber)?.doubleValue ?? 0
            let dy = (payload[HelperPayloadFields.scrollDY] as? NSNumber)?.doubleValue ?? 0
            let total = sqrt(dx * dx + dy * dy)
            let identity = appIdentity(forPID: pid)
            stats.addScrollDistance(total * 10, appIdentity: identity)

            let metadata = ScrollEventMetadata(
                scrollPhaseRaw: (payload[HelperPayloadFields.scrollPhase] as? NSNumber)?.int64Value ?? 0,
                momentumPhaseRaw: (payload[HelperPayloadFields.scrollMomentumPhase] as? NSNumber)?.int64Value ?? 0,
                isContinuous: (payload[HelperPayloadFields.scrollIsContinuous] as? NSNumber)?.boolValue ?? false
            )
            handleScrollSession(metadata, appIdentity: identity, stats: stats)

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            guard let x = (payload[HelperPayloadFields.locationX] as? NSNumber)?.doubleValue,
                  let y = (payload[HelperPayloadFields.locationY] as? NSNumber)?.doubleValue
            else { return }
            let current = CGPoint(x: x, y: y)
            if let last = stats.lastMousePosition {
                let dx = current.x - last.x
                let dy = current.y - last.y
                let d = sqrt(dx * dx + dy * dy)
                if d < 500 {
                    if stats.isMouseDistanceCalibrating {
                        stats.recordMouseDistanceCalibration(d)
                    } else {
                        stats.addMouseDistance(d)
                    }
                }
            }
            stats.lastMousePosition = current

        default:
            break
        }
    }

    private func appIdentity(forPID pid: pid_t) -> AppIdentity? {
        guard stats.appStatsEnabled else { return nil }
        return AppActivityTracker.shared.appIdentity(forPID: pid)
    }

    private func recordReplay(_ payload: [String: Any], growthName: String? = nil) {
        guard let timestamp = (payload[HelperPayloadFields.replayTimestamp] as? NSNumber)?.uint64Value,
              let code = (payload[HelperPayloadFields.keyCode] as? NSNumber)?.uint16Value,
              let raw = payload[HelperPayloadFields.replayPhase] as? String,
              let phase = KeyReplayEvent.Phase(rawValue: raw) else {
            onReplayGap()
            return
        }
        let keys = growthName.map { Array(PhysicalKeyMapping.map([$0: 1]).counts.keys).sorted() } ?? []
        onReplay(timestamp, code, phase, keys)
    }

    private func handleScrollSession(
        _ event: ScrollEventMetadata,
        appIdentity: AppIdentity?,
        stats: StatsManager
    ) {
        var completedSession = false
        var completedAppIdentity: AppIdentity?

        scrollSessionLock.lock()
        switch scrollSessionTracker.consume(event) {
        case .began:
            activeScrollSessionAppIdentity = appIdentity
        case .completed:
            completedSession = true
            completedAppIdentity = activeScrollSessionAppIdentity
            activeScrollSessionAppIdentity = nil
        case .cancelled:
            activeScrollSessionAppIdentity = nil
        case .none:
            break
        }
        scrollSessionLock.unlock()

        if completedSession {
            stats.incrementScrollSessions(appIdentity: completedAppIdentity)
        }
    }
}
