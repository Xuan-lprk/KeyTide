import Cocoa
import MetalKit
import IOKit.hidsystem

extension Notification.Name {
    static let keyboardTypingSelectionChanged = Notification.Name("Keytide.keyboardTypingSelectionChanged")
}

/// Only currently animating virtual clicks. No statistics or input history.
struct MechanicalFullPressState {
    private struct Impulse { let began: Double; let initial: Double }
    let supported: Set<String>
    private var active: [String: Impulse] = [:]
    var activeCount: Int { active.count }
    var profile = MechanicalPressProfile.deep
    init(supported: Set<String>) {
        self.supported = supported
    }
    mutating func press(_ id: String, at time: Double) {
        guard supported.contains(id) else { return }
        let initial = active[id].map { profile.weight(time - $0.began, initial: $0.initial) } ?? 0
        active[id] = Impulse(began: time, initial: initial)
    }
    mutating func offsets(at time: Double, reduceMotion: Bool = false) -> [String: CGFloat] {
        active = active.filter { time - $0.value.began < profile.duration }
        return active.mapValues { profile.travel * (reduceMotion ? 0.5 : 1) * profile.weight(time - $0.began, initial: $0.initial) }
    }
    mutating func cancel() { active.removeAll() }
}

struct KeyboardLegendMark {
    let text: String
    let symbol: Bool
    let rect: CGRect
    let fontSize: CGFloat
    let font: NSFont
    init(text: String, symbol: Bool = false, rect: CGRect, fontSize: CGFloat,
         font: NSFont = .systemFont(ofSize: 12, weight: .medium)) {
        self.text = text
        self.symbol = symbol
        self.rect = rect
        self.fontSize = fontSize
        self.font = font
    }
}

enum KeyboardLegendLayout {
    static let functionSymbols = ["sun.min", "sun.max", "rectangle.3.group", "magnifyingglass",
        "mic", "moon", "backward.fill", "playpause.fill", "forward.fill", "speaker.slash.fill",
        "speaker.wave.1.fill", "speaker.wave.3.fill"]
    static let ink = NSColor(srgbRed: 0.20, green: 0.27, blue: 0.31, alpha: 1)
    static let symbols: [String: NSImage] = Dictionary(uniqueKeysWithValues:
        (functionSymbols + ["globe"]).compactMap { name in
            NSImage(systemSymbolName: name, accessibilityDescription: nil).map { (name, $0) }
        })

    static func marks(for key: EditorialKeyboardSceneKey, top: CGRect) -> [KeyboardLegendMark] {
        guard key.id != "Space", top.width > 0, top.height > 0 else { return [] }
        let edge = min(6, top.width * 0.10)
        let safe = top.insetBy(dx: edge, dy: min(4, top.height * 0.09))
        let unit = min(safe.width, safe.height)
        var result: [KeyboardLegendMark] = []
        func mark(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat,
                  alignment: NSTextAlignment = .center, symbol: Bool = false) {
            let base = min(18, min(top.width, top.height) * 0.40)
            let fontSize = min(size, base * (symbol ? 0.94 : 0.90))
            let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [.font: font]))
            let ink = CTLineGetImageBounds(line, nil)
            // Use visible ink for both placement and drawing, not typographic line height.
            let measured = symbol ? CGSize(width: fontSize, height: fontSize) : ink.size
            let factor = min(1, safe.width / max(1, measured.width), safe.height / max(1, measured.height))
            let finalFont = NSFont.systemFont(ofSize: fontSize * factor, weight: .medium)
            let scaled = CGSize(width: measured.width * factor, height: measured.height * factor)
            let originX = alignment == .left ? x : alignment == .right ? x - scaled.width : x - scaled.width / 2
            let rect = CGRect(x: min(max(safe.minX, originX), safe.maxX - scaled.width),
                y: min(max(safe.minY, y - scaled.height / 2), safe.maxY - scaled.height),
                width: scaled.width, height: scaled.height)
            result.append(.init(text: text, symbol: symbol, rect: rect,
                fontSize: finalFont.pointSize, font: finalFont))
        }
        let font = min(18, unit * 0.40)
        if key.id.hasPrefix("F"), let index = Int(key.id.dropFirst()), (1...12).contains(index) {
            mark(functionSymbols[index - 1], x: safe.midX,
                 y: safe.minY + safe.height * 0.40, size: min(13, unit * 0.29), symbol: true)
            mark(key.id, x: safe.midX, y: safe.minY + safe.height * 0.78,
                 size: min(9, unit * 0.20))
        } else if let label = ["Tab": "tab", "CapsLock": "caps lock",
                              "LeftShift": "shift", "RightShift": "shift",
                              "Delete": "delete", "Return": "return"][key.id] {
            let right = ["Delete", "Return", "RightShift"].contains(key.id)
            mark(label, x: right ? safe.maxX : safe.minX, y: safe.maxY,
                 size: min(13, unit * 0.30), alignment: right ? .right : .left)
        } else if let glyph = ["Esc": "esc", "Fn": "fn"][key.id] {
            if key.id == "Fn" {
                mark(glyph, x: safe.minX, y: safe.minY + safe.height * 0.20,
                     size: min(10, unit * 0.25), alignment: .left)
                mark("globe", x: safe.minX, y: safe.minY + safe.height * 0.72,
                     size: min(11, unit * 0.28), alignment: .left, symbol: true)
            } else {
                mark(glyph, x: safe.minX, y: safe.midY, size: min(11, unit * 0.28), alignment: .left)
            }
        } else if ["Up", "Down", "Left", "Right"].contains(key.id) {
            let arrows = ["Up": "↑", "Down": "↓", "Left": "←", "Right": "→"]
            mark(arrows[key.id]!, x: safe.midX, y: safe.midY, size: min(15, unit * 0.48))
        } else if let pair = ["Ctrl": ("⌃", "control"), "LeftOption": ("⌥", "option"),
                            "RightOption": ("⌥", "option"), "LeftCmd": ("⌘", "command"),
                            "RightCmd": ("⌘", "command")][key.id] {
            let right = key.id.hasPrefix("Right")
            mark(pair.0, x: right ? safe.maxX : safe.minX, y: safe.minY + safe.height * 0.28,
                 size: font * 0.85, alignment: right ? .right : .left)
            mark(pair.1, x: safe.midX, y: safe.maxY, size: min(11, unit * 0.27))
        } else {
            let lines = key.legend.string.components(separatedBy: "\n")
            if lines.count == 2 {
                mark(lines[0], x: safe.midX, y: safe.minY + safe.height * 0.30,
                     size: font * 0.78)
                mark(lines[1], x: safe.midX, y: safe.minY + safe.height * 0.66,
                     size: font * 0.90)
            } else {
                mark(key.legend.string, x: safe.midX,
                     y: safe.midY, size: font)
            }
        }
        return result
    }

    static func draw(_ mark: KeyboardLegendMark) {
        if mark.symbol {
            symbols[mark.text]?.draw(in: mark.rect, from: .zero, operation: .sourceOver,
                fraction: 0.85, respectFlipped: true, hints: nil)
            return
        }
        let attributed = NSAttributedString(string: mark.text, attributes: [
            .font: mark.font, .foregroundColor: ink])
        let line = CTLineCreateWithAttributedString(attributed)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = CTLineGetImageBounds(line, nil)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: mark.rect.minX - bounds.minX, y: mark.rect.minY + bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    static func draw(keys: [EditorialKeyboardSceneKey], rects: [String: CGRect]) {
        for key in keys {
            guard let rect = rects[key.id] else { continue }
            for mark in marks(for: key, top: rect) {
                draw(mark)
            }
            ink.withAlphaComponent(0.45).setFill()
            if key.id == "F" || key.id == "J" {
                NSBezierPath(roundedRect: CGRect(x: rect.midX - 3, y: rect.minY + rect.height * 0.73,
                    width: 6, height: 1), xRadius: 0.5, yRadius: 0.5).fill()
            }
            if key.id == "CapsLock" {
                NSBezierPath(ovalIn: CGRect(x: rect.minX + 4, y: rect.minY + 3, width: 2, height: 2)).fill()
            }
        }
    }
}

final class KeyboardLegendOverlay: NSView {
    private let keys: [EditorialKeyboardSceneKey]
    private let model: MechanicalKeyboardScene?
    var pixelScale: CGFloat = 1
    var usesSnapshotProjection = false
    var rects: [String: CGRect] = [:] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    init(model: MechanicalKeyboardScene) {
        self.model = model; keys = model.keys
        super.init(frame: CGRect(origin: .zero, size: MechanicalKeyboardScene.size))
    }
    init(keys: [EditorialKeyboardSceneKey]) {
        self.keys = keys; model = nil
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        // AppKit already maps bounds into frame; an additional scale would distort labels.
        let projected = model.map { model in
            Dictionary(uniqueKeysWithValues: keys.map { ($0.id, model.legendRect(for: $0, pixelScale: pixelScale, snapshot: usesSnapshotProjection)) })
        } ?? rects
        KeyboardLegendLayout.draw(keys: keys, rects: projected)
    }
}

private final class MechanicalClickView: MTKView {
    var clicked: ((NSEvent) -> Void)?
    override func mouseDown(with event: NSEvent) { clicked?(event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// MTKView stays paused between finite keyboard and mouse press impulses.
final class MechanicalKeyboardView: NSView, MTKViewDelegate {
    static let size = CGSize(width: 1320, height: 820)
    let model: MechanicalKeyboardScene
    private let metal: MechanicalClickView
    private let legends: KeyboardLegendOverlay
    private let queue: MTLCommandQueue
    private var state: MechanicalFullPressState
    private let selection = NSTextField(labelWithString: "")
    private var pending: DispatchWorkItem?
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private(set) var drawCount = 0
    var hasScheduledFrame: Bool { pending != nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    static func physicalKeyID(_ code: UInt16) -> String? { physicalKeys[code] }
    private static let physicalKeys: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`",
        51: "Delete", 53: "Esc", 54: "RightCmd", 55: "LeftCmd", 56: "LeftShift", 57: "CapsLock",
        58: "LeftOption", 59: "Ctrl", 60: "RightShift", 61: "RightOption", 62: "Ctrl", 63: "Fn",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10",
        111: "F12", 118: "F4", 120: "F2", 122: "F1", 123: "Left", 124: "Right", 125: "Down", 126: "Up"
    ]
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            press("Tab")
            let destination = event.modifierFlags.contains(.shift) ? previousKeyView : nextKeyView
            window?.makeFirstResponder(destination)
            return
        }
        guard !event.isARepeat, !event.modifierFlags.contains(.command),
              let id = Self.physicalKeys[event.keyCode] else { super.keyDown(with: event); return }
        press(id)
    }
    override func flagsChanged(with event: NSEvent) {
        if let id = Self.modifierPressKeyID(event.keyCode, flags: event.modifierFlags) { press(id) }
    }
    static func modifierPressKeyID(_ code: UInt16, flags: NSEvent.ModifierFlags) -> String? {
        // Caps Lock changes its toggle state on each press, including turning off.
        if code == 57 { return physicalKeyID(code) }
        if code == 63 { return flags.contains(.function) ? physicalKeyID(code) : nil }
        let masks: [UInt16: UInt] = [
            54: UInt(NX_DEVICERCMDKEYMASK), 55: UInt(NX_DEVICELCMDKEYMASK),
            56: UInt(NX_DEVICELSHIFTKEYMASK), 60: UInt(NX_DEVICERSHIFTKEYMASK),
            58: UInt(NX_DEVICELALTKEYMASK), 61: UInt(NX_DEVICERALTKEYMASK),
            59: UInt(NX_DEVICELCTLKEYMASK), 62: UInt(NX_DEVICERCTLKEYMASK)]
        guard let mask = masks[code], flags.rawValue & mask != 0 else { return nil }
        return physicalKeyID(code)
    }
    private var eligible: Bool {
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible) && !window.isMiniaturized
            && !isHiddenOrHasHiddenAncestor && !NSApp.isHidden
    }
    init(model: MechanicalKeyboardScene, embedded: Bool = false) {
        self.model = model
        state = MechanicalFullPressState(supported: Set(model.keys.map(\.id)))
        state.profile = model.isMacModel ? .light : .deep
        legends = KeyboardLegendOverlay(model: model)
        metal = MechanicalClickView(frame: CGRect(origin: .zero, size: MechanicalKeyboardScene.size), device: model.metalDevice)
        queue = model.metalDevice.makeCommandQueue()!
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        wantsLayer = true; layer?.backgroundColor = MechanicalKeyboardScene.canvas.cgColor
        appearance = NSAppearance(named: .aqua)
        let title = NSTextField(labelWithString: NSLocalizedString("Mechanical Keyboard · Click to press", comment: "Mechanical Keyboard"))
        title.font = .systemFont(ofSize: 23, weight: .medium)
        title.frame = CGRect(x: 20, y: 12, width: 1280, height: 32); addSubview(title)
        title.isHidden = embedded
        let note = NSTextField(labelWithString: NSLocalizedString("77 keys · mouse only · 160 ms press · fixed height", comment: "Mechanical Keyboard"))
        if embedded {
            note.stringValue = NSLocalizedString("keyboard.interaction.hint", comment: "Keyboard interaction")
        }
        note.font = .systemFont(ofSize: 13); note.textColor = .secondaryLabelColor
        note.frame = CGRect(x: 20, y: 49, width: 1280, height: 24); addSubview(note)
        note.isHidden = embedded
        metal.frame.origin = CGPoint(x: 20, y: 77)
        metal.isPaused = true; metal.enableSetNeedsDisplay = false
        metal.colorPixelFormat = .bgra8Unorm_srgb; metal.depthStencilPixelFormat = .depth32Float_stencil8
        metal.sampleCount = 4; metal.delegate = self
        metal.layer?.isOpaque = false
        addSubview(metal)
        legends.frame = metal.frame
        addSubview(legends)
        selection.stringValue = NSLocalizedString("Click a keycap to test its press and return.", comment: "Mechanical Keyboard")
        selection.font = .systemFont(ofSize: 12); selection.textColor = .secondaryLabelColor
        selection.frame = CGRect(x: 20, y: 795, width: 1280, height: 22); addSubview(selection)
        selection.isHidden = embedded
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(NSLocalizedString("keyboard.interaction.description", comment: "Keyboard interaction"))
        setAccessibilityHelp(NSLocalizedString("keyboard.interaction.help", comment: "Keyboard interaction"))
        metal.setAccessibilityElement(false)
        metal.clicked = { [weak self] event in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            let point = self.convert(event.locationInWindow, from: nil)
            let topPoint = CGPoint(x: point.x - self.metal.frame.minX, y: point.y - self.metal.frame.minY)
            if let id = self.model.fullKey(at: topPoint, pixelScale: self.metal.drawableSize.width / MechanicalKeyboardScene.size.width) {
                self.press(id)
            }
        }
    }

    func applyStudioStyle() {
        model.setTransparentCanvas(true)
        layer?.backgroundColor = nil
        metal.layer?.isOpaque = false
        metal.clearColor = MTLClearColorMake(0, 0, 0, 0)
        drawOnce()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { pending?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cancel(); observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification] {
            if let window { observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.cancel() }) }
        }
        if let window {
            observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in
                guard let self else { return }
                if self.eligible { self.updateDisplayResolution() } else { self.cancel() }
            })
        }
        for name in [NSApplication.didResignActiveNotification, NSApplication.didHideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.cancel() })
        }
        if window != nil { DispatchQueue.main.async { [weak self] in self?.drawOnce() } }
    }
    override func viewDidHide() { super.viewDidHide(); cancel() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateDisplayResolution() }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { drawOnce() }
    func draw(in view: MTKView) {
        guard eligible else { return }
        model.drawFullModel(in: view, queue: queue); drawCount += 1
        legends.pixelScale = metal.drawableSize.width / MechanicalKeyboardScene.size.width
        legends.needsDisplay = true
    }
    private func drawOnce() { if eligible { metal.draw() } }
    func updateDisplayResolution() {
        guard eligible, let window else { return }
        let size = window.convertToBacking(metal.convert(metal.bounds, to: nil)).size
        if size.width > 0, size.height > 0, metal.drawableSize != size {
            metal.autoResizeDrawable = false
            metal.drawableSize = size
        }
        drawOnce()
    }
    func press(_ id: String) {
        guard eligible, state.supported.contains(id) else { return }
        state.press(id, at: ProcessInfo.processInfo.systemUptime)
        selection.stringValue = String(format: NSLocalizedString("Selected key: %@", comment: "Mechanical Keyboard"), id)
        setAccessibilityValue(selection.stringValue)
        NotificationCenter.default.post(name: .keyboardTypingSelectionChanged, object: self, userInfo: ["id": id])
        if pending == nil { tick() }
    }
    private func tick() {
        pending = nil
        guard eligible else { cancel(); return }
        let next = DispatchTime.now() + 1.0 / 60
        model.applyFullPress(state.offsets(at: ProcessInfo.processInfo.systemUptime,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
        drawOnce()
        guard state.activeCount > 0 else { return }
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.tick()
        }
        pending = work; DispatchQueue.main.asyncAfter(deadline: next, execute: work)
    }
    func exportImage() -> NSImage? {
        cancel()
        let snapshot = model.snapshot()
        let exportLegends = KeyboardLegendOverlay(model: model)
        exportLegends.pixelScale = 3
        exportLegends.usesSnapshotProjection = true
        guard let bitmap = KeyboardImageBitmap.make(size: MechanicalKeyboardScene.size, draw: {
            snapshot.draw(in: CGRect(origin: .zero, size: MechanicalKeyboardScene.size), from: .zero,
                          operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            exportLegends.draw(CGRect(origin: .zero, size: MechanicalKeyboardScene.size))
        }) else { return nil }
        return KeyboardImageBitmap.image(bitmap)
    }

    func cancel() {
        guard pending != nil || state.activeCount > 0 else { return }
        generation += 1; pending?.cancel(); pending = nil; state.cancel()
        model.applyFullPress([:]); drawOnce()
    }

}
