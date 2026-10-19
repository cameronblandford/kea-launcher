import AppKit
import Quartz
import LauncherCore

final class LauncherPanel: NSPanel {
    weak var controller: PanelController?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    @objc func quickLook(_ sender: Any?) { controller?.toggleQuickLook() }

    /// The app is never active, so route Cmd shortcuts to the menu bar ourselves.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = controller
        panel.delegate = controller
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

/// The floating search window: text field on top, results table below.
final class PanelController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate,
                             QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let panel: LauncherPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var results: [Result] = []
    private(set) var shown = false
    private let coordinator: SearchCoordinator
    private let scripts: ScriptCommands

    private let width: CGFloat = 680
    private let rowHeight: CGFloat = 46
    private let baseFieldHeight: CGFloat = 56
    private var fieldHeight: CGFloat = 56
    private var fieldHeightConstraint: NSLayoutConstraint!
    private var scrollTopConstraint: NSLayoutConstraint!

    /// "a | b | c" in config picks one of them each time the panel opens.
    private let placeholders: [String]
    private let theme: Theme
    private let fontSize: CGFloat
    private let animate: Bool
    /// On macOS 26 and later the hidden panel stays on screen at alpha 0, so opening it
    /// is only an alpha change. Before that it is ordered out while hidden, because on
    /// macOS 14 an alpha-0 window that joins all Spaces shows during Space switches.
    private let keepWarm = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    private var opal: OpalView?

    init(coordinator: SearchCoordinator, scripts: ScriptCommands, placeholder: String = "Search", appearance: Config.Appearance = Config.Appearance()) {
        self.coordinator = coordinator
        self.scripts = scripts
        let options = placeholder.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        self.placeholders = options.isEmpty ? ["Search"] : options
        self.theme = Theme.resolve(appearance)
        self.fontSize = CGFloat(appearance.fontSize)
        self.animate = appearance.animate ?? (theme.skin != nil)
        RowBackground.selectionColor = theme.selectionColor
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: fieldHeight),
                              styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init()
        panel.controller = self
        setupPanel()
        setupViews()
        coordinator.onResults = { [weak self] in self?.show(results: $0) }
    }

    private func setupPanel() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none          // no zoom/fade on orderFront
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        if let name = theme.appearance { panel.appearance = NSAppearance(named: name) }
        let effect = NSVisualEffectView()
        effect.material = theme.material
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        panel.contentView = effect
        if let skin = theme.skin {
            let view = OpalView(style: skin)
            view.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: effect.topAnchor), view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: effect.leadingAnchor), view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            ])
            opal = view
        }
        if let bg = theme.background, theme.tintAlpha > 0 {
            let tint = NSView()
            tint.wantsLayer = true
            tint.layer?.backgroundColor = bg.withAlphaComponent(theme.tintAlpha).cgColor
            tint.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(tint)
            NSLayoutConstraint.activate([
                tint.topAnchor.constraint(equalTo: effect.topAnchor), tint.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
                tint.leadingAnchor.constraint(equalTo: effect.leadingAnchor), tint.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            ])
        }

        // The panel is non-activating so the app behind keeps focus, like Raycast.
        // Close it when the user switches apps or clicks outside instead of on key loss.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.shown, !self.quickLookVisible else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                Log.write("other app activated")
                self.hide()
            }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.shown, !self.quickLookVisible else { return }
            Log.write("click outside")
            self.hide()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self, self.shown else { return }
            Log.write("panel resigned key (still shown, key=\(self.panel.isKeyWindow))")
        }
    }

    private func setupViews() {
        guard let content = panel.contentView else { return }

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: fontSize, weight: .light)
        field.placeholderString = placeholders[0]
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.cell?.sendsActionOnEndEditing = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = width - 36
        content.addSubview(field)

        let column = NSTableColumn(identifier: .init("main"))
        column.width = width
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(activateSelected)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        fieldHeightConstraint = field.heightAnchor.constraint(equalToConstant: fieldHeight - 24)
        scrollTopConstraint = scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: fieldHeight)
        fieldHeightConstraint.isActive = true
        scrollTopConstraint.isActive = true
    }

    // MARK: - Show / hide

    /// Orders the panel in once at alpha 0 so its views, layers and backing store exist
    /// before the first hotkey. With `keepWarm` (macOS 26+) it then stays on screen, invisible, and
    /// opening is only an alpha change (about 4 ms). Without it the panel is ordered out
    /// between uses (about 30 ms to open): on macOS 14 an alpha-0 window that joins all
    /// Spaces shows during the Space-switch animation.
    func warmUp() {
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.setFrame(frameFor(rows: coordinator.cachedRecent().count), display: true)
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        if !shown, !keepWarm { panel.orderOut(nil) }
    }

    private func frameFor(rows: Int) -> NSRect { frameFor(height: heightFor(rows: rows)) }

    private func frameFor(height: CGFloat) -> NSRect {
        let f = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let top = f.minY + f.height * 0.62
        return NSRect(x: f.midX - width / 2, y: top - height, width: width, height: height)
    }

    func toggle() {
        if shown { hide() } else { show() }
    }

    private var previousApp: NSRunningApplication?

    func show() {
        var t = CFAbsoluteTimeGetCurrent()
        var marks: [String] = []
        func mark(_ name: String) { let n = CFAbsoluteTimeGetCurrent(); marks.append("\(name)=\(Int((n - t) * 1000))"); t = n }
        previousApp = NSWorkspace.shared.frontmostApplication
        if placeholders.count > 1 { field.placeholderString = placeholders.randomElement() }
        field.stringValue = ""
        updateFieldHeight()
        // Recent items are precomputed, so the first frame already has the right height.
        results = coordinator.cachedRecent()
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        mark("prep")
        let frame = frameFor(height: heightFor(results: results))
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        mark("frame")
        shown = true
        panel.ignoresMouseEvents = false
        if animate { playOpenAnimation() } else { panel.alphaValue = 1 }
        opal?.startDrift()
        if !panel.isVisible { panel.orderFrontRegardless() }
        mark("order")
        panel.makeKey()
        mark("key")
        panel.makeFirstResponder(field)
        mark("responder")
        Log.write("panel shown: \(marks.joined(separator: " ")) ms, \(results.count) rows")
        // After the panel is up: a date check, and one background request on a new day.
        coordinator.preloadWeather()
    }

    /// A quick fade, and a light sweep on the Opal skin. The panel never changes size while
    /// it opens (by design, no theme changes its size as it opens). Input goes to the
    /// field at once; only the drawing animates. Reduce Motion keeps just the fade.
    private func playOpenAnimation() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        opal?.playSweep()
    }

    func hide() {
        guard shown else { return }
        shown = false
        opal?.stopDrift()
        if quickLookVisible { QLPreviewPanel.shared().orderOut(nil) }
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.resignKey()
        if !keepWarm { panel.orderOut(nil) }
        results = []
        table.reloadData()
        coordinator.cancelLive()
        coordinator.refreshRecent()
        // Pre-size for the next open so no resize happens on the hotkey.
        panel.setFrame(frameFor(rows: coordinator.cachedRecent().count), display: false)
        Log.write("panel hidden")
        if let prev = previousApp, prev.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            prev.activate()
        }
        previousApp = nil
    }

    private let maxListHeight: CGFloat = 46 * 9
    private static let subtitleFont = NSFont.systemFont(ofSize: 12)

    /// Fixed height for normal rows; measured height for expanded ones.
    private func height(of r: Result) -> CGFloat {
        guard r.expanded, let text = r.subtitle, !text.isEmpty else { return rowHeight }
        let textWidth = width - 18 - 30 - 12 - 18
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: 400),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Self.subtitleFont])
        return min(400, max(rowHeight, 6 + 18 + 2 + ceil(bounds.height) + 8))
    }

    private func heightFor(results: [Result]) -> CGFloat {
        var total: CGFloat = 0
        for r in results {
            total += height(of: r)
            if total >= maxListHeight { total = maxListHeight; break }
        }
        return fieldHeight + total + (results.isEmpty ? 0 : 8)
    }

    private func heightFor(rows count: Int) -> CGFloat {
        heightFor(results: Array(coordinator.cachedRecent().prefix(count)))
    }

    private func show(results new: [Result]) {
        guard shown else { return }
        let keepRow = results.map(\.id) == new.map(\.id) ? table.selectedRow : 0
        results = new
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([max(0, keepRow)], byExtendingSelection: false) }
        resizePanel(to: heightFor(results: results))
    }

    // MARK: - Text field

    func controlTextDidChange(_ obj: Notification) {
        updateFieldHeight()
        coordinator.update(text: field.stringValue)
    }

    /// Grows the search field when the query wraps, and pushes the list and panel down.
    private func updateFieldHeight() {
        let text = field.stringValue.isEmpty ? "X" : field.stringValue
        let font = field.font ?? NSFont.systemFont(ofSize: fontSize, weight: .light)
        let rect = (text as NSString).boundingRect(with: NSSize(width: width - 36, height: 1000),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   attributes: [.font: font])
        let textHeight = max(baseFieldHeight - 24, ceil(rect.height) + 4)
        let newHeight = min(textHeight + 24, 200)
        guard newHeight != fieldHeight else { return }
        fieldHeight = newHeight
        fieldHeightConstraint.constant = newHeight - 24
        scrollTopConstraint.constant = newHeight
        resizePanel(to: heightFor(results: results))
    }

    private func resizePanel(to height: CGFloat) {
        var frame = panel.frame
        guard frame.height != height else { return }
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - height
        panel.setFrame(frame, display: true, animate: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true { revealSelected() } else { activateSelected() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { hide() } else { field.stringValue = ""; updateFieldHeight(); coordinator.update(text: "") }
            return true
        case #selector(NSResponder.deleteForward(_:)):
            return deleteSelected()
        case #selector(NSResponder.deleteBackward(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true { return deleteSelected() }
            return false
        case #selector(NSResponder.insertTab(_:)):
            // Tab completes a list command's keyword.
            if let r = results.first(where: { $0.id == selectedID }), let cmd = scripts.command(forID: r.id), cmd.manifest.mode == .list {
                field.stringValue = cmd.manifest.keyword + " "
                textView.setSelectedRange(NSRange(location: field.stringValue.count, length: 0))
                coordinator.update(text: field.stringValue)
            }
            return true
        default:
            return false
        }
    }

    private var selectedID: String? {
        let row = table.selectedRow
        return row >= 0 && row < results.count ? results[row].id : nil
    }

    private func move(by delta: Int) {
        guard !results.isEmpty else { return }
        let next = max(0, min(results.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
        if quickLookVisible { QLPreviewPanel.shared().reloadData() }
    }

    // MARK: - Quick Look

    private var quickLookVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    private var selectedPreviewPath: String? {
        let row = table.selectedRow
        guard row >= 0, row < results.count else { return nil }
        return results[row].revealPath
    }

    func toggleQuickLook() {
        if quickLookVisible {
            QLPreviewPanel.shared().orderOut(nil)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard selectedPreviewPath != nil else { return }
        QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedPreviewPath == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        selectedPreviewPath.map { URL(fileURLWithPath: $0) as NSURL }
    }

    /// Arrow keys inside Quick Look move the launcher selection; Return opens the item.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 125: move(by: 1); return true
        case 126: move(by: -1); return true
        case 36: panel.orderOut(nil); activateSelected(); return true
        default: return false
        }
    }

    @objc private func activateSelected() {
        let row = table.selectedRow
        guard row >= 0, row < results.count else { return }
        let r = results[row]
        if let cmd = scripts.command(forID: r.id), cmd.manifest.mode == .list {
            field.stringValue = cmd.manifest.keyword + " "
            if let editor = field.currentEditor() { editor.selectedRange = NSRange(location: field.stringValue.count, length: 0) }
            coordinator.update(text: field.stringValue)
            return
        }
        if case .fill(let text) = r.action {
            field.stringValue = text
            if let editor = field.currentEditor() { editor.selectedRange = NSRange(location: text.count, length: 0) }
            updateFieldHeight()
            coordinator.update(text: text)
            return
        }
        if case .runScript(let url, _) = r.action {
            // Action commands receive whatever follows the matched text as their argument.
            let arg = field.stringValue.trimmingCharacters(in: .whitespaces)
            coordinator.recordUse(r.id)
            hide()
            Actions.perform(.runScript(url, argument: arg), scripts: scripts)
            return
        }
        coordinator.recordUse(r.id)
        hide()
        Actions.perform(r.action, scripts: scripts)
    }

    /// fn+Delete (forward delete) or Cmd+Delete. Files and notes go to the Trash; clipboard entries are removed.
    private func deleteSelected() -> Bool {
        let row = table.selectedRow
        guard row >= 0, row < results.count, let onDelete = results[row].onDelete else { return false }
        onDelete()
        coordinator.update(text: field.stringValue)
        if !results.isEmpty {
            let next = min(row, results.count - 1)
            table.selectRowIndexes([next], byExtendingSelection: false)
        }
        return true
    }

    private func revealSelected() {
        let row = table.selectedRow
        guard row >= 0, row < results.count, let path = results[row].revealPath else { activateSelected(); return }
        coordinator.recordUse(results[row].id)
        hide()
        Actions.reveal(path)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        row < results.count ? height(of: results[row]) : rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let view = (tableView.makeView(withIdentifier: id, owner: nil) as? ResultRowView) ?? ResultRowView(identifier: id)
        view.configure(results[row])
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RowBackground()
    }
}

final class RowBackground: NSTableRowView {
    static var selectionColor: NSColor = NSColor.controlAccentColor.withAlphaComponent(0.25)

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let r = bounds.insetBy(dx: 8, dy: 2)
        Self.selectionColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
    }
}

final class ResultRowView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let keys = KeyCapsView()
    private var iconCenter: NSLayoutConstraint!
    private var iconTop: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 15)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        keys.setContentHuggingPriority(.required, for: .horizontal)
        keys.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [icon, title, subtitle, keys] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        iconCenter = icon.centerYAnchor.constraint(equalTo: centerYAnchor)
        iconTop = icon.topAnchor.constraint(equalTo: topAnchor, constant: 8)
        iconCenter.isActive = true
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            // The key caps have no width when a row has no shortcut.
            keys.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            keys.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(equalTo: keys.leadingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ r: Result) {
        icon.image = r.icon
        title.stringValue = r.title
        subtitle.stringValue = r.subtitle ?? ""
        subtitle.isHidden = r.subtitle == nil
        keys.keys = r.keys
        if r.expanded {
            subtitle.font = .systemFont(ofSize: 12)
            subtitle.textColor = .labelColor
            subtitle.maximumNumberOfLines = 0
            subtitle.lineBreakMode = .byWordWrapping
            subtitle.preferredMaxLayoutWidth = 680 - 18 - 30 - 12 - 18
            iconCenter.isActive = false
            iconTop.isActive = true
        } else {
            subtitle.font = .systemFont(ofSize: 11)
            subtitle.textColor = .secondaryLabelColor
            subtitle.maximumNumberOfLines = 1
            subtitle.lineBreakMode = .byTruncatingMiddle
            iconTop.isActive = false
            iconCenter.isActive = true
        }
    }
}

/// A shortcut as key caps: one gray rounded square for each key, with a monospaced label.
final class KeyCapsView: NSView {
    var keys: [String] = [] { didSet { if keys != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    private static let side: CGFloat = 22, gap: CGFloat = 3

    private func width(of key: String) -> CGFloat {
        max(Self.side, ceil((key as NSString).size(withAttributes: [.font: Self.font]).width) + 10)
    }

    override var intrinsicContentSize: NSSize {
        keys.isEmpty ? NSSize(width: 0, height: Self.side)
            : NSSize(width: keys.map(width).reduce(0, +) + Self.gap * CGFloat(keys.count - 1), height: Self.side)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        for key in keys {
            let w = width(of: key)
            let cap = NSRect(x: x, y: 0, width: w, height: Self.side)
            let path = NSBezierPath(roundedRect: cap.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            // Label colors follow the appearance, so the caps work on each theme.
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.14).setStroke()
            path.stroke()
            let text = NSAttributedString(string: key, attributes: [.font: Self.font, .foregroundColor: NSColor.secondaryLabelColor])
            let size = text.size()
            text.draw(at: NSPoint(x: x + (w - size.width) / 2, y: (Self.side - size.height) / 2))
            x += w + Self.gap
        }
    }
}
