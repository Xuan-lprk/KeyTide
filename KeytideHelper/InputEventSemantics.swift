import Foundation
import CoreGraphics
import Carbon
import IOKit.hidsystem

private let leftControlRawMask = UInt64(NX_DEVICELCTLKEYMASK)
private let rightControlRawMask = UInt64(NX_DEVICERCTLKEYMASK)
private let leftShiftRawMask = UInt64(NX_DEVICELSHIFTKEYMASK)
private let rightShiftRawMask = UInt64(NX_DEVICERSHIFTKEYMASK)
private let leftCommandRawMask = UInt64(NX_DEVICELCMDKEYMASK)
private let rightCommandRawMask = UInt64(NX_DEVICERCMDKEYMASK)
private let leftOptionRawMask = UInt64(NX_DEVICELALTKEYMASK)
private let rightOptionRawMask = UInt64(NX_DEVICERALTKEYMASK)

func standaloneModifierHeatmapKeyName(for keyCode: Int) -> String? {
    switch keyCode {
    case 55:
        return "LeftCmd"
    case 54:
        return "RightCmd"
    case 56:
        return "LeftShift"
    case 60:
        return "RightShift"
    case 58:
        return "LeftOption"
    case 61:
        return "RightOption"
    default:
        return nil
    }
}

private enum StandaloneModifierFamily {
    case shift
    case option
    case command
}

private func standaloneModifierFamily(for keyCode: Int) -> StandaloneModifierFamily? {
    switch keyCode {
    case 55, 54:
        return .command
    case 56, 60:
        return .shift
    case 58, 61:
        return .option
    default:
        return nil
    }
}

private func standaloneModifierFamily(for keyName: String) -> StandaloneModifierFamily? {
    switch keyName {
    case "Cmd":
        return .command
    case "LeftCmd", "RightCmd":
        return .command
    case "Shift":
        return .shift
    case "LeftShift", "RightShift":
        return .shift
    case "Option":
        return .option
    case "LeftOption", "RightOption":
        return .option
    default:
        return nil
    }
}

private func standaloneModifierKeyName(from rawFlags: UInt64, family: StandaloneModifierFamily) -> String? {
    switch family {
    case .shift:
        if rawFlags & rightShiftRawMask != 0 { return "RightShift" }
        if rawFlags & leftShiftRawMask != 0 { return "LeftShift" }
    case .option:
        if rawFlags & rightOptionRawMask != 0 { return "RightOption" }
        if rawFlags & leftOptionRawMask != 0 { return "LeftOption" }
    case .command:
        if rawFlags & rightCommandRawMask != 0 { return "RightCmd" }
        if rawFlags & leftCommandRawMask != 0 { return "LeftCmd" }
    }

    return nil
}

func standaloneModifierHeatmapKeyName(for keyCode: Int, rawFlags: UInt64) -> String? {
    guard let family = standaloneModifierFamily(for: keyCode) else {
        return standaloneModifierHeatmapKeyName(for: keyCode)
    }

    return standaloneModifierKeyName(from: rawFlags, family: family) ?? standaloneModifierHeatmapKeyName(for: keyCode)
}

func isStandaloneModifierPress(rawFlags: UInt64, keyCode: Int) -> Bool {
    guard let family = standaloneModifierFamily(for: keyCode) else { return false }
    return standaloneModifierKeyName(from: rawFlags, family: family) != nil
}

func isStandaloneHeatmapModifierKey(_ keyName: String) -> Bool {
    switch keyName {
    case "LeftShift", "RightShift", "LeftOption", "RightOption", "LeftCmd", "RightCmd":
        return true
    default:
        return false
    }
}

func keyboardEventModifierNames(rawFlags: UInt64, keyCode: Int) -> [String] {
    let flags = CGEventFlags(rawValue: rawFlags)
    var names: [String] = []

    if rawFlags & leftCommandRawMask != 0 {
        names.append("LeftCmd")
    }
    if rawFlags & rightCommandRawMask != 0 {
        names.append("RightCmd")
    }
    if !names.contains("LeftCmd") && !names.contains("RightCmd") && flags.contains(.maskCommand) {
        names.append("Cmd")
    }

    if rawFlags & leftShiftRawMask != 0 {
        names.append("LeftShift")
    }
    if rawFlags & rightShiftRawMask != 0 {
        names.append("RightShift")
    }
    if !names.contains("LeftShift") && !names.contains("RightShift") && flags.contains(.maskShift) {
        names.append("Shift")
    }

    if rawFlags & leftOptionRawMask != 0 {
        names.append("LeftOption")
    }
    if rawFlags & rightOptionRawMask != 0 {
        names.append("RightOption")
    }
    if !names.contains("LeftOption") && !names.contains("RightOption") && flags.contains(.maskAlternate) {
        names.append("Option")
    }

    if rawFlags & leftControlRawMask != 0 || rawFlags & rightControlRawMask != 0 || flags.contains(.maskControl) {
        names.append("Ctrl")
    }

    let isNavigationKey = (123...126).contains(keyCode) || [115, 116, 119, 121, 117].contains(keyCode)
    let isFnKey = [63, 179].contains(keyCode)
    if flags.contains(.maskSecondaryFn) && !isNavigationKey && !isFnKey {
        names.append("Fn")
    }

    return names
}

struct ModifierStandaloneTracker {
    private var pendingModifierKeys: Set<String> = []

    mutating func handleFlagsChanged(keyCode: Int, rawFlags: UInt64) -> String? {
        guard let modifierFamily = standaloneModifierFamily(for: keyCode) else { return nil }
        let modifierKey = standaloneModifierHeatmapKeyName(for: keyCode, rawFlags: rawFlags)

        if isStandaloneModifierPress(rawFlags: rawFlags, keyCode: keyCode) {
            if let modifierKey {
                pendingModifierKeys.insert(modifierKey)
            }
            return nil
        }

        if let modifierKey, pendingModifierKeys.remove(modifierKey) != nil {
            return modifierKey
        }

        guard let familyMatch = pendingModifierKeys.first(where: { standaloneModifierFamily(for: $0) == modifierFamily }) else {
            return nil
        }

        pendingModifierKeys.remove(familyMatch)
        return familyMatch
    }

    mutating func consumePendingModifiers(forKeyDownWith rawFlags: UInt64, keyCode: Int) {
        for modifierKey in keyboardEventModifierNames(rawFlags: rawFlags, keyCode: keyCode) {
            if isStandaloneHeatmapModifierKey(modifierKey) {
                pendingModifierKeys.remove(modifierKey)
                continue
            }

            guard let family = standaloneModifierFamily(for: modifierKey) else { continue }
            pendingModifierKeys = pendingModifierKeys.filter { standaloneModifierFamily(for: $0) != family }
        }
    }

    mutating func reset() {
        pendingModifierKeys.removeAll()
    }
}

enum ScrollEventPhase: Int64 {
    case none = 0
    case began = 1
    case changed = 2
    case ended = 4
    case cancelled = 8
    case mayBegin = 128
}

enum ScrollMomentumPhase: Int64 {
    case none = 0
    case began = 1
    case changed = 2
    case ended = 3
}

struct ScrollEventMetadata {
    let phase: ScrollEventPhase
    let momentumPhase: ScrollMomentumPhase
    let isContinuous: Bool

    init(scrollPhaseRaw: Int64, momentumPhaseRaw: Int64, isContinuous: Bool) {
        phase = ScrollEventPhase(rawValue: scrollPhaseRaw) ?? .none
        momentumPhase = ScrollMomentumPhase(rawValue: momentumPhaseRaw) ?? .none
        self.isContinuous = isContinuous
    }
}

enum ScrollSessionTransition: Equatable {
    case none
    case began
    case completed
    case cancelled
}

struct ScrollSessionTracker {
    private(set) var isActive = false

    mutating func consume(_ event: ScrollEventMetadata) -> ScrollSessionTransition {
        switch event.phase {
        case .began:
            isActive = true
            return .began
        case .ended:
            guard isActive else { return .none }
            isActive = false
            return .completed
        case .cancelled:
            let wasActive = isActive
            isActive = false
            return wasActive ? .cancelled : .none
        case .none, .changed, .mayBegin:
            return .none
        }
    }
}

/// Key names derived from the current layout without reading typed text.
final class InputEventDecoder {
    static let shared = InputEventDecoder()

    private let layoutLock = NSLock()
    private var cachedLayoutData: CFData?
    private var inputSourceObserver: NSObjectProtocol?

    private init() {
        startInputSourceMonitoring()
        refreshKeyboardLayoutCache()
    }

    deinit {
        if let observer = inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    func keyName(keyCode: Int, keyboardType: UInt32, flagsRaw: UInt64) -> String {
        let base = baseKeyName(for: keyCode, keyboardType: keyboardType)
        let modifiers = keyboardEventModifierNames(rawFlags: flagsRaw, keyCode: keyCode)
        if modifiers.isEmpty { return base }
        return modifiers.joined(separator: "+") + "+" + base
    }

    private func baseKeyName(for keyCode: Int, keyboardType: UInt32) -> String {
        if let mapped = Self.keyCodeMap[keyCode] {
            return mapped
        }
        if let asciiName = asciiKeyName(for: keyCode, keyboardType: keyboardType) {
            return asciiName
        }
        return "Key\(keyCode)"
    }

    private static let keyCodeMap: [Int: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        63: "Fn", 64: "F17", 71: "Clear", 76: "Enter", 79: "F18",
        80: "F19", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16",
        107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help",
        115: "Home", 116: "PageUp", 117: "ForwardDelete", 118: "F4",
        119: "End", 120: "F2", 121: "PageDown", 122: "F1", 123: "Left",
        124: "Right", 125: "Down", 126: "Up", 179: "Fn"
    ]

    private func startInputSourceMonitoring() {
        let name = NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.refreshKeyboardLayoutCache()
        }
    }

    private func refreshKeyboardLayoutCache() {
        let currentSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let currentDataPtr = currentSource.flatMap { TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData) }
        var layoutData = currentDataPtr.map { Unmanaged<CFData>.fromOpaque($0).takeUnretainedValue() }
        if layoutData == nil {
            if let asciiSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
                let asciiDataPtr = TISGetInputSourceProperty(asciiSource, kTISPropertyUnicodeKeyLayoutData)
                layoutData = asciiDataPtr.map { Unmanaged<CFData>.fromOpaque($0).takeUnretainedValue() }
            }
        }
        layoutLock.lock()
        cachedLayoutData = layoutData
        layoutLock.unlock()
    }

    private func asciiKeyName(for keyCode: Int, keyboardType: UInt32) -> String? {
        layoutLock.lock()
        let layoutData = cachedLayoutData
        layoutLock.unlock()
        guard let layoutData = layoutData else { return nil }
        guard let layoutPtr = CFDataGetBytePtr(layoutData) else { return nil }
        let keyboardLayout = unsafeBitCast(layoutPtr, to: UnsafePointer<UCKeyboardLayout>.self)

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var actualLength: Int = 0
        let modifiers: UInt32 = 0
        let status = UCKeyTranslate(
            keyboardLayout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDown),
            modifiers,
            keyboardType,
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &actualLength,
            &chars
        )

        guard status == noErr, actualLength > 0 else { return nil }
        let raw = String(utf16CodeUnits: chars, count: actualLength)
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count == 1 else { return nil }
        if cleaned == " " { return "Space" }
        if cleaned == "\t" { return "Tab" }
        if cleaned == "\r" { return "Return" }
        return cleaned.uppercased()
    }
}
