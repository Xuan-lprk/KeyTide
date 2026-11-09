import Cocoa
import UniformTypeIdentifiers

/// A full-width, on-demand 3D stage. The two menu styles share one layout.
final class KeyboardVisualizationViewController: NSViewController {
    private let growth = GrowthKeyboardViewController(manager: .shared, startsIn3D: true)
    private let models = NSSegmentedControl()
    private let interaction = NSSegmentedControl()
    private let stage = KeyboardStudioStageView()
    private let content = NSView()
    private let insight = KeyboardKeyInsightCard()
    private let typingPanel = KeyboardStudioPanel()
    private let typingKey = keyboardStudioLabel("—", size: 22, weight: .medium)
    private let typingHint = NSTextField(wrappingLabelWithString: "")
    private let replayToggle = NSButton()
    private let exportButton = NSButton()
    private let total = keyboardStudioLabel("", size: 24, weight: .medium)
    private let totalCaption = keyboardStudioLabel("", size: 10)
    private let date = keyboardStudioLabel("", size: 11)
    private var surfaces: [Int: MechanicalKeyboardView] = [:]
    private var typingSelectionObservers: [Int: NSObjectProtocol] = [:]
    private var styleObserver: NSObjectProtocol?
    private var selection: GrowthKeyboardSidebarSelection?
    private var replayCollapsed = false
    private var replayHeight: NSLayoutConstraint?
    private var prefersInteraction = false
    private var style: MenuUIStyle = .standard
    private var palette: KeyboardStudioPalette { KeyboardStudioPalette(style: style) }
    var onPageChanged: ((Bool) -> Void)?
    var showsGrowth: Bool { true }

    deinit {
        typingSelectionObservers.values.forEach(NotificationCenter.default.removeObserver)
        if let styleObserver { NotificationCenter.default.removeObserver(styleObserver) }
    }

    override func loadView() {
        style = MenuUIStyle.current
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        view.addSubview(stage)
        stage.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stage.topAnchor.constraint(equalTo: view.topAnchor),
            stage.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let brand = keyboardStudioLabel("K E Y T I D E", size: 10, weight: .semibold)
        let title = keyboardStudioLabel(NSLocalizedString("growth.title", comment: ""), size: 20, weight: .semibold)
        totalCaption.stringValue = NSLocalizedString("growth.metric.caption", comment: "")
        let totalBlock = keyboardStudioStack([totalCaption, total], vertical: true, spacing: 2)
        date.maximumNumberOfLines = 2
        date.cell?.wraps = true
        date.cell?.isScrollable = false
        date.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        date.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
        let heading = keyboardStudioStack([brand, title, totalBlock, date], vertical: true, spacing: 4)
        models.segmentCount = 2
        models.setLabel("Mac", forSegment: 0)
        models.setLabel(NSLocalizedString("keyboard.model.mechanical", comment: ""), forSegment: 1)
        models.selectedSegment = 0; models.segmentStyle = .rounded
        models.target = self; models.action = #selector(changeModel)
        models.setAccessibilityLabel(NSLocalizedString("keyboard.model.choose", comment: ""))
        interaction.segmentCount = 2
        interaction.setLabel(NSLocalizedString("keyboard.mode.growth", comment: ""), forSegment: 0)
        interaction.setLabel(NSLocalizedString("keyboard.interaction", comment: ""), forSegment: 1)
        interaction.selectedSegment = 0; interaction.segmentStyle = .rounded
        interaction.target = self; interaction.action = #selector(toggleInteraction)
        interaction.setAccessibilityLabel(NSLocalizedString("keyboard.mode.choose", comment: ""))
        exportButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        exportButton.bezelStyle = .texturedRounded
        exportButton.imagePosition = .imageOnly
        exportButton.toolTip = NSLocalizedString("keyboard.export.title", comment: "")
        exportButton.setAccessibilityLabel(exportButton.toolTip)
        exportButton.target = self
        exportButton.action = #selector(showImageActions)
        let header = NSStackView(views: [heading, keyboardStudioSpace(), models, interaction, exportButton])
        header.alignment = .centerY; header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(header)

        content.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(content)
        growth.transportView.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(growth.transportView)
        replayHeight = growth.transportView.heightAnchor.constraint(equalToConstant: 48)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -28),
            header.topAnchor.constraint(equalTo: stage.topAnchor, constant: 18),
            content.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: growth.transportView.topAnchor, constant: -4),
            growth.transportView.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 28),
            growth.transportView.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -64),
            growth.transportView.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -20),
            replayHeight!
        ])

        replayToggle.bezelStyle = .inline; replayToggle.isBordered = false
        replayToggle.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        replayToggle.target = self; replayToggle.action = #selector(toggleReplay)
        replayToggle.setAccessibilityLabel(NSLocalizedString("keyboard.replay.toggle", comment: "Keyboard Studio"))
        replayToggle.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(replayToggle)
        NSLayoutConstraint.activate([
            replayToggle.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -20),
            replayToggle.centerYAnchor.constraint(equalTo: growth.transportView.centerYAnchor),
            replayToggle.widthAnchor.constraint(equalToConstant: 28),
            replayToggle.heightAnchor.constraint(equalToConstant: 28)
        ])

        addChild(growth)
        content.addSubview(growth.view)
        growth.view.frame = content.bounds
        growth.view.autoresizingMask = [.width, .height]
        growth.onSummaryChanged = { [weak self] total, date, coverage in
            self?.total.stringValue = total
            if let self { self.totalCaption.stringValue = self.growth.metricTitle }
            self?.date.stringValue = date
            self?.date.toolTip = coverage
        }
        growth.onSelectionChanged = { [weak self] selection in
            self?.selection = selection
            self?.updateInsight()
        }
        insight.onClose = { [weak self] in self?.dismissInsight() }
        stage.onBackgroundClick = { [weak self] in self?.dismissInsight() }
        insight.isHidden = true
        stage.addSubview(insight)
        // Position in stage coordinates directly; AppKit anchors use visual
        // edge directions even when the view's frame coordinates grow upward.
        insight.autoresizingMask = []

        typingHint.stringValue = NSLocalizedString("keyboard.typing.compact", comment: "Keyboard Studio")
        typingHint.font = .systemFont(ofSize: 11)
        typingHint.maximumNumberOfLines = 2
        let typingContent = keyboardStudioStack([typingKey, typingHint], vertical: true, spacing: 3)
        typingContent.translatesAutoresizingMaskIntoConstraints = false
        typingPanel.addSubview(typingContent)
        NSLayoutConstraint.activate([
            typingContent.leadingAnchor.constraint(equalTo: typingPanel.leadingAnchor, constant: 14),
            typingContent.trailingAnchor.constraint(equalTo: typingPanel.trailingAnchor, constant: -14),
            typingContent.topAnchor.constraint(equalTo: typingPanel.topAnchor, constant: 10),
            typingContent.bottomAnchor.constraint(equalTo: typingPanel.bottomAnchor, constant: -10)
        ])
        typingPanel.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(typingPanel)
        NSLayoutConstraint.activate([
            typingPanel.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 28),
            typingPanel.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -20),
            typingPanel.widthAnchor.constraint(equalToConstant: 270)
        ])
        typingPanel.isHidden = true
        applyStyle()
        changeModel()
        styleObserver = NotificationCenter.default.addObserver(forName: .menuUIStyleDidChange,
            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.style = MenuUIStyle.current
            self.applyStyle()
        }
    }

    private func applyStyle() {
        let p = palette
        stage.style = style
        stage.needsDisplay = true
        view.window?.appearance = NSAppearance(named: .darkAqua)
        view.window?.backgroundColor = p.background
        tintLabels(in: view, palette: p)
        total.textColor = p.text; totalCaption.textColor = p.secondary; date.textColor = p.secondary
        typingKey.textColor = p.accent; typingHint.textColor = p.secondary
        typingPanel.palette = p
        replayToggle.contentTintColor = p.secondary
        if let selection { insight.update(selection, palette: p) }
        growth.refreshCanvas()
        for surface in surfaces.values { surface.applyStudioStyle() }
    }

    private func updateInsight() {
        guard let selection, !prefersInteraction else {
            insight.isHidden = true
            return
        }
        insight.update(selection, palette: palette)
        insight.isHidden = false
        positionInsight()
    }

    private func positionInsight() {
        guard !insight.isHidden, let keyFrame = growth.selectedKeyFrame() else { return }
        let target = stage.convert(keyFrame, from: growth.view)
        let size = insight.fittingSize
        let width = max(310, size.width), height = max(92, size.height)
        let safe = content.convert(content.bounds, to: stage).insetBy(dx: 2, dy: 2)
        let maxX = max(safe.minX, safe.maxX - width)
        let maxY = max(safe.minY, safe.maxY - height)
        var x = min(max(safe.minX, target.midX - width / 2), maxX)
        // Stage coordinates grow upward; place the card above the cap when possible.
        let above = target.maxY + 12
        var y = above <= maxY ? above : target.minY - height - 12
        y = min(max(safe.minY, y), maxY)
        if CGRect(x: x, y: y, width: width, height: height).intersects(target) {
            // A short stage may have room beside a cap rather than above it.
            x = target.maxX + 12 <= maxX ? target.maxX + 12 : target.minX - width - 12
            x = min(max(safe.minX, x), maxX)
        }
        let frame = CGRect(x: x, y: y, width: width, height: height)
        if insight.frame != frame { insight.frame = frame }
    }

    private func dismissInsight() {
        let focused = view.window?.firstResponder as? NSView
        let restoresFocus = focused.map { $0 === insight || $0.isDescendant(of: insight) } ?? false
        growth.clearKeySelection()
        if restoresFocus {
            func keyboard(in view: NSView) -> GrowthKeyboard3DRenderer? {
                if let renderer = view as? GrowthKeyboard3DRenderer, !renderer.isHiddenOrHasHiddenAncestor { return renderer }
                return view.subviews.lazy.compactMap { keyboard(in: $0) }.first
            }
            view.window?.makeFirstResponder(keyboard(in: growth.view))
        }
    }

    @objc private func showImageActions() {
        exportButton.toolTip = NSLocalizedString("keyboard.export.title", comment: "")
        let menu = NSMenu()
        for (key, action) in [("keyboard.export.title", #selector(exportKeyboardImage)),
                              ("keyboard.export.copy", #selector(copyKeyboardImage)),
                              ("keyboard.export.copyClean", #selector(copyCleanKeyboardImage))] {
            let item = NSMenuItem(title: NSLocalizedString(key, comment: ""), action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: exportButton.bounds.minX, y: exportButton.bounds.maxY + 4), in: exportButton)
    }

    @objc private func copyKeyboardImage() { copyImage(includeDetails: true) }
    @objc private func copyCleanKeyboardImage() { copyImage(includeDetails: false) }

    private func copyImage(includeDetails: Bool) {
        let image: NSImage
        var summary: String?, coverage: String?
        if prefersInteraction, let value = surfaces[models.selectedSegment]?.exportImage() {
            image = value
        } else if !prefersInteraction, let value = growth.exportCurrentImage() {
            image = value.image; summary = value.summary; coverage = value.coverage
        } else {
            showImageError(NSLocalizedString("keyboard.export.notReady", comment: "")); return
        }
        let model = models.selectedSegment == 0 ? "Mac" : NSLocalizedString("keyboard.model.mechanical", comment: "")
        let mode = prefersInteraction ? NSLocalizedString("keyboard.interaction", comment: "") : growth.displayedScopeTitle
        guard let data = KeyboardStudioImageExport.png(keyboard: image, model: model, mode: mode,
            summary: includeDetails ? summary : nil, coverage: includeDetails ? coverage : nil, style: style),
              KeyboardStudioImageExport.copyPNG(data) else {
            showImageError(NSLocalizedString("keyboard.export.copyFailed", comment: "")); return
        }
        let message = NSLocalizedString("keyboard.export.copied", comment: "")
        exportButton.toolTip = message
        NSAccessibility.post(element: exportButton, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func showImageError(_ message: String) {
        guard let window = view.window else { return }
        let alert = NSAlert(); alert.messageText = message
        alert.beginSheetModal(for: window)
    }

    func showDay(_ date: Date) {
        _ = view
        prefersInteraction = false
        changeModel()
        if replayCollapsed { toggleReplay() }
        growth.showDay(date)
    }

    @objc private func exportKeyboardImage() {
        guard let window = view.window else { return }
        let image: NSImage
        var summary: String?
        var coverage: String?
        if prefersInteraction, let exported = surfaces[models.selectedSegment]?.exportImage() {
            image = exported
        } else if !prefersInteraction, let exported = growth.exportCurrentImage() {
            image = exported.image; summary = exported.summary; coverage = exported.coverage
        } else {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("keyboard.export.notReady", comment: "")
            alert.beginSheetModal(for: window)
            return
        }
        let model = models.selectedSegment == 0 ? "Mac" : NSLocalizedString("keyboard.model.mechanical", comment: "")
        let mode = prefersInteraction ? NSLocalizedString("keyboard.interaction", comment: "") : growth.displayedScopeTitle
        let exportStyle = style
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Keytide-\(models.selectedSegment == 0 ? "Mac" : "Mechanical").png"
        panel.title = NSLocalizedString("keyboard.export.title", comment: "")
        let includeDetails = NSButton(checkboxWithTitle: NSLocalizedString("keyboard.export.includeDetails", comment: ""), target: nil, action: nil)
        includeDetails.state = .on
        if !prefersInteraction { panel.accessoryView = includeDetails }
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do {
                guard let data = KeyboardStudioImageExport.png(keyboard: image, model: model, mode: mode,
                    summary: includeDetails.state == .on ? summary : nil,
                    coverage: includeDetails.state == .on ? coverage : nil, style: exportStyle) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: url, options: .atomic)
            } catch {
                guard let window = self?.view.window else { return }
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc private func toggleReplay() {
        replayCollapsed.toggle()
        replayHeight?.constant = replayCollapsed ? 24 : 48
        growth.setTransportCollapsed(replayCollapsed)
        replayToggle.image = NSImage(systemSymbolName: replayCollapsed ? "chevron.up" : "chevron.down",
            accessibilityDescription: nil)
        insight.isHidden = selection == nil || prefersInteraction
        positionInsight()
    }

    @objc private func changeModel() {
        let index = models.selectedSegment
        if prefersInteraction && surfaces[index] == nil {
            do {
                let model = try MechanicalKeyboardScene()
                if index == 0 { try model.configureMacModel() }
                else { try model.configureFullModel() }
                let surface = MechanicalKeyboardView(model: model, embedded: true)
                content.addSubview(surface)
                surfaces[index] = surface
                surface.applyStudioStyle()
                typingSelectionObservers[index] = NotificationCenter.default.addObserver(
                    forName: .keyboardTypingSelectionChanged, object: surface, queue: .main) {
                    [weak self] notification in
                    self?.typingKey.stringValue = notification.userInfo?["id"] as? String ?? "—"
                }
            } catch {
                models.selectedSegment = 0; prefersInteraction = false
                NSAlert(error: error).runModal()
                changeModel()
                return
            }
        }
        for (candidate, surface) in surfaces {
            surface.cancel()
            surface.isHidden = !prefersInteraction || candidate != index
        }
        growth.view.isHidden = prefersInteraction
        replayHeight?.constant = prefersInteraction ? 0 : (replayCollapsed ? 24 : 48)
        growth.transportView.isHidden = prefersInteraction
        replayToggle.isHidden = prefersInteraction
        typingPanel.isHidden = !prefersInteraction
        if !prefersInteraction { growth.setMechanical(index == 1) }
        growth.setPresented(!prefersInteraction)
        interaction.selectedSegment = prefersInteraction ? 1 : 0
        typingKey.stringValue = "—"
        updateInsight()
        layoutSurfaces()
        if prefersInteraction, let surface = surfaces[index] {
            surface.nextKeyView = interaction
            models.nextKeyView = surface
            view.window?.makeFirstResponder(surface)
        } else if let focused = view.window?.firstResponder as? NSView,
                  surfaces.values.contains(where: { focused === $0 || focused.isDescendant(of: $0) }) {
            view.window?.makeFirstResponder(interaction)
        }
    }

    @objc private func toggleInteraction() {
        prefersInteraction = interaction.selectedSegment == 1
        changeModel()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutSurfaces()
        positionInsight()
    }

    private func layoutSurfaces() {
        for surface in surfaces.values {
            let scale = max(0.01, min(content.bounds.width / MechanicalKeyboardView.size.width,
                content.bounds.height / MechanicalKeyboardView.size.height))
            let size = CGSize(width: MechanicalKeyboardView.size.width * scale,
                height: MechanicalKeyboardView.size.height * scale)
            surface.frame = CGRect(x: (content.bounds.width - size.width) / 2,
                y: (content.bounds.height - size.height) / 2, width: size.width, height: size.height)
            surface.setBoundsSize(MechanicalKeyboardView.size)
        }
    }

    func refreshForPresentation(resetToToday: Bool) {
        _ = view
        growth.setPresented(!growth.view.isHidden)
        growth.refreshData(resetToToday: resetToToday)
    }
}
