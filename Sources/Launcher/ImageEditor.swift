import AppKit
import LauncherCore

/// `ie`: a small editor for the image on the clipboard. Draw, box, highlight, redact,
/// add arrows and text labels in a pastel sticker style, then Return copies the result
/// back to the clipboard and closes. `ie <instructions>` asks Claude to place the marks,
/// and they open here for you to adjust.
final class ImageEditor: NSObject, NSWindowDelegate {
    private static var open: [ImageEditor] = []

    let window: NSWindow
    private let canvas: EditorCanvas
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let tools = NSSegmentedControl()
    private var swatches: [NSButton] = []
    private let image: NSImage
    private let pixelSize: CGSize

    static let toolOrder: [(Markup.Kind, String, String)] = [
        (.arrow, "arrow.up.right", "Arrow (A)"), (.box, "rectangle", "Box (B)"), (.text, "textformat", "Text (T)"),
        (.pen, "scribble", "Pen (P)"), (.highlight, "highlighter", "Highlight (H)"), (.redact, "eye.slash", "Redact (R)"),
        (.mosaic, "square.grid.3x3.fill", "Mosaic (M)"),
    ]

    /// The image on the clipboard and its size in pixels, if there is one.
    static func clipboardImage() -> (NSImage, CGSize)? {
        guard let img = NSImage(pasteboard: NSPasteboard.general) else { return nil }
        let rep = img.representations.max { $0.pixelsWide < $1.pixelsWide }
        let px = rep.map { CGSize(width: max($0.pixelsWide, 1), height: max($0.pixelsHigh, 1)) } ?? img.size
        guard px.width > 1, px.height > 1 else { return nil }
        return (img, px)
    }

    @discardableResult
    static func show(image: NSImage, pixelSize: CGSize, onScreen: Bool = true) -> ImageEditor {
        let e = ImageEditor(image: image, pixelSize: pixelSize)
        open.append(e)
        guard onScreen else { return e }
        NSApp.activate(ignoringOtherApps: true)
        e.window.makeKeyAndOrderFront(nil)
        e.window.makeFirstResponder(e.canvas)
        return e
    }

    private init(image: NSImage, pixelSize: CGSize) {
        self.image = image
        self.pixelSize = pixelSize
        // Fit the image in most of the screen, never upscaled past its pixel size in points.
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let scale = (NSScreen.main?.backingScaleFactor ?? 2)
        let natural = CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        let fit = min(1, (screen.width * 0.8) / natural.width, (screen.height * 0.75 - 90) / natural.height)
        let shown = CGSize(width: max(natural.width * fit, 480), height: max(natural.height * fit, 200))
        canvas = EditorCanvas(image: image, size: shown)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: shown.width + 32, height: shown.height + 104),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "ie ⟡"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = NSColor(name: nil) { a in
            a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 0.13, green: 0.12, blue: 0.16, alpha: 1)
                                                                : NSColor(srgbRed: 0.98, green: 0.96, blue: 0.99, alpha: 1)
        }
        build()
        canvas.onChange = { [weak self] in self?.updateStatus() }
        window.center()
    }

    private func build() {
        guard let content = window.contentView else { return }
        tools.segmentCount = Self.toolOrder.count
        tools.trackingMode = .selectOne
        for (i, t) in Self.toolOrder.enumerated() {
            tools.setImage(NSImage(systemSymbolName: t.1, accessibilityDescription: t.2), forSegment: i)
            tools.setToolTip(t.2, forSegment: i)
            tools.setWidth(36, forSegment: i)
        }
        tools.selectedSegment = 0
        tools.target = self
        tools.action = #selector(toolChanged)

        let palette = NSStackView()
        palette.spacing = 6
        for (i, c) in PastelColor.allCases.enumerated() {
            let b = NSButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
            b.title = ""
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 11
            b.layer?.backgroundColor = MarkupRenderer.color(c).cgColor
            b.layer?.borderColor = NSColor.white.cgColor
            b.tag = i
            b.target = self
            b.action = #selector(colorChanged(_:))
            b.toolTip = "\(c.rawValue.capitalized) (\(i + 1))"
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
            palette.addArrangedSubview(b)
            swatches.append(b)
        }
        let undo = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo")!, target: self, action: #selector(undoMark))
        undo.toolTip = "Undo (Cmd+Z)"
        let save = NSButton(title: "Save…", target: self, action: #selector(saveAs))
        let done = NSButton(title: "Copy ⟡ Done", target: self, action: #selector(copyAndClose))
        done.keyEquivalent = "\r"
        done.bezelColor = MarkupRenderer.color(.lilac)

        let bar = NSStackView(views: [tools, palette, NSView(), undo, save, done])
        bar.spacing = 12
        status.textColor = .secondaryLabelColor
        status.font = MarkupRenderer.font(size: 12, weight: .medium)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let footer = NSStackView(views: [spinner, status])
        footer.spacing = 6
        for v in [bar, canvas, footer] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 34),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            canvas.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            canvas.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            canvas.widthAnchor.constraint(equalToConstant: canvas.frame.width),
            canvas.heightAnchor.constraint(equalToConstant: canvas.frame.height),
            footer.topAnchor.constraint(equalTo: canvas.bottomAnchor, constant: 6),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
        ])
        selectColor(.pink)
        updateStatus()
    }

    // MARK: Actions

    @objc private func toolChanged() { canvas.tool = Self.toolOrder[tools.selectedSegment].0; updateStatus() }
    @objc private func colorChanged(_ b: NSButton) { selectColor(PastelColor.allCases[b.tag]) }
    @objc private func undoMark() { canvas.undo() }

    func selectTool(_ k: Markup.Kind) {
        guard let i = Self.toolOrder.firstIndex(where: { $0.0 == k }) else { return }
        tools.selectedSegment = i
        toolChanged()
    }

    func selectColor(_ c: PastelColor) {
        canvas.color = c
        for (i, b) in swatches.enumerated() { b.layer?.borderWidth = PastelColor.allCases[i] == c ? 3 : 0 }
    }

    private func pngData() -> Data? { MarkupRenderer.export(image, pixelSize: pixelSize, marks: canvas.marks) }

    @objc func copyAndClose() {
        guard let data = pngData() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        if let img = NSImage(data: data), let tiff = img.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        Log.write("ie: copied \(Int(pixelSize.width))x\(Int(pixelSize.height)) with \(canvas.marks.count) marks")
        window.close()
    }

    @objc private func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "ie \(f.string(from: Date())).png"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url, let data = self?.pngData() else { return }
            try? data.write(to: url)
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }

    // MARK: Claude

    private var working = false

    func setWorking(_ text: String) {
        working = true
        spinner.startAnimation(nil)
        status.stringValue = text
    }

    func addMarks(_ marks: [Markup], note: String) {
        working = false
        spinner.stopAnimation(nil)
        canvas.add(marks)
        status.stringValue = note.isEmpty ? "Claude added \(marks.count) mark\(marks.count == 1 ? "" : "s") ⟡ adjust, then Return copies" : "✦ \(note)"
    }

    func fail(_ text: String) {
        working = false
        spinner.stopAnimation(nil)
        status.stringValue = text
    }

    private func updateStatus() {
        guard !working else { return }
        let tool = Self.toolOrder.first { $0.0 == canvas.tool }?.2 ?? ""
        status.stringValue = "\(tool) ⋆ \(canvas.marks.count) mark\(canvas.marks.count == 1 ? "" : "s") ⋆ drag a mark to move it ⋆ Return copies ⋆ Cmd+Z undo ⋆ Esc closes"
    }
}

/// The image and its marks. Drag on empty space to draw with the current tool (click with
/// Text to type); drag an existing mark to move it. Option always draws.
final class EditorCanvas: NSView, NSTextFieldDelegate {
    var tool: Markup.Kind = .arrow
    var color: PastelColor = .pink
    private(set) var marks: [Markup] = []
    private var undoStack: [[Markup]] = []
    private var draft: Markup?
    /// A mark being dragged: its index, where the drag began, and how it was before.
    private var moving: (index: Int, start: Markup.Point, original: Markup, moved: Bool)?
    private let image: NSImage
    private var editor: NSTextField?
    private var editorPoint = Markup.Point(0, 0)
    var onChange: (() -> Void)?

    init(image: NSImage, size: CGSize) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        MarkupRenderer.draw(marks + (draft.map { [$0] } ?? []), in: bounds, image: image)
    }

    private func norm(_ e: NSEvent) -> Markup.Point {
        let p = convert(e.locationInWindow, from: nil)
        return Markup.Point(min(max(p.x / bounds.width, 0), 1), min(max(p.y / bounds.height, 0), 1))
    }

    private func commit(_ change: () -> Void) {
        undoStack.append(marks)
        change()
        needsDisplay = true
        onChange?()
    }

    func add(_ new: [Markup]) { guard !new.isEmpty else { return }; commit { marks += new } }

    func undo() {
        guard let prev = undoStack.popLast() else { NSSound.beep(); return }
        marks = prev
        needsDisplay = true
        onChange?()
    }

    /// The topmost mark under `p`, if any.
    private func markIndex(at p: Markup.Point) -> Int? {
        marks.indices.reversed().first { i in
            let m = marks[i]
            let size = m.kind == .text ? MarkupRenderer.textPillSize(m, in: bounds) : .zero
            return m.hit(p, width: bounds.width, height: bounds.height, tolerance: 10, textSize: (w: Double(size.width), h: Double(size.height)))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    /// An open hand over a mark that a drag would move.
    override func mouseMoved(with e: NSEvent) {
        let over = !e.modifierFlags.contains(.option) && markIndex(at: norm(e)) != nil
        (over ? NSCursor.openHand : NSCursor.crosshair).set()
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        finishText()
        let p = norm(e)
        // A drag that starts on a mark moves it. Option draws a new mark there instead.
        if !e.modifierFlags.contains(.option), let i = markIndex(at: p) {
            moving = (i, p, marks[i], false)
            NSCursor.closedHand.set()
            return
        }
        if tool == .text { beginText(at: p); return }
        // Redaction is always ink: a pastel block would not hide much.
        draft = Markup(kind: tool, points: [p, p], color: tool == .redact || tool == .mosaic ? .ink : color)
    }

    override func mouseDragged(with e: NSEvent) {
        if var mv = moving {
            let p = norm(e)
            // The whole move is one undo step, saved when the mark first moves.
            if !mv.moved { undoStack.append(marks); mv.moved = true; moving = mv }
            marks[mv.index] = mv.original.moved(dx: p.x - mv.start.x, dy: p.y - mv.start.y)
            needsDisplay = true
            return
        }
        guard var d = draft else { return }
        let p = norm(e)
        if d.kind == .pen { d.points.append(p) } else { d.points[1] = p }
        draft = d
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if let mv = moving {
            moving = nil
            NSCursor.openHand.set()
            if mv.moved { onChange?() }
            return
        }
        guard let d = draft else { return }
        draft = nil
        let a = MarkupRenderer.point(d.points[0], in: bounds), b = MarkupRenderer.point(d.points[d.points.count - 1], in: bounds)
        // Ignore stray clicks: a mark needs some size.
        if d.kind == .pen ? d.points.count > 2 : hypot(a.x - b.x, a.y - b.y) > 6 { commit { marks.append(d) } }
        needsDisplay = true
    }

    /// Drives the canvas with synthetic mouse events in an offscreen window and prints what
    /// happened (`Launcher --ie-selftest`): a drag on a mark moves it, a drag on empty space
    /// draws, Option draws on top of a mark, and one undo puts a moved mark back.
    static func selfTest() {
        let size = CGSize(width: 800, height: 400)
        let canvas = EditorCanvas(image: NSImage(size: size), size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.tool = .arrow
        canvas.add([Markup(kind: .redact, points: [.init(0.25, 0.25), .init(0.5, 0.5)], color: .ink)])
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double, option: Bool = false) -> NSEvent {
            // Window coordinates have a bottom-left origin; the canvas is flipped.
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x * size.width, y: (1 - y) * size.height), modifierFlags: option ? .option : [],
                               timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func drag(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, option: Bool = false) {
            canvas.mouseDown(with: event(.leftMouseDown, x0, y0, option: option))
            canvas.mouseDragged(with: event(.leftMouseDragged, (x0 + x1) / 2, (y0 + y1) / 2, option: option))
            canvas.mouseDragged(with: event(.leftMouseDragged, x1, y1, option: option))
            canvas.mouseUp(with: event(.leftMouseUp, x1, y1, option: option))
        }
        func show(_ label: String) {
            let text = canvas.marks.map { m in "\(m.kind.rawValue)" + m.points.prefix(2).map { String(format: "(%.2f,%.2f)", $0.x, $0.y) }.joined() }.joined(separator: "  ")
            print("\(label): \(text)")
        }
        show("start")
        drag(0.3, 0.3, 0.5, 0.4);                 show("drag on the redact block")
        drag(0.05, 0.9, 0.2, 0.8);                show("drag on empty space")
        drag(0.5, 0.45, 0.9, 0.9, option: true);  show("Option-drag on the block")
        canvas.undo(); canvas.undo(); canvas.undo(); show("after three undos")
    }

    // MARK: Text

    private func beginText(at p: Markup.Point) {
        let f = NSTextField(string: "")
        f.font = MarkupRenderer.font(size: 22 * MarkupRenderer.unit(for: bounds))
        f.placeholderString = "type, then Return"
        f.isBordered = false
        f.drawsBackground = true
        f.backgroundColor = MarkupRenderer.color(color).withAlphaComponent(0.9)
        f.textColor = MarkupRenderer.color(color == .ink ? .pink : .ink)
        f.focusRingType = .none
        f.delegate = self
        let pt = MarkupRenderer.point(p, in: bounds)
        f.frame = NSRect(x: pt.x, y: pt.y, width: max(160, bounds.width - pt.x - 8), height: f.font!.pointSize * 1.5)
        addSubview(f)
        window?.makeFirstResponder(f)
        editor = f
        editorPoint = p
    }

    private func finishText() {
        guard let f = editor else { return }
        editor = nil
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        f.removeFromSuperview()
        if !text.isEmpty { commit { marks.append(Markup(kind: .text, points: [editorPoint], color: color, text: text)) } }
        window?.makeFirstResponder(self)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { finishText(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { editor?.stringValue = ""; finishText(); return true }
        return false
    }

    // MARK: Keys

    override func keyDown(with e: NSEvent) {
        let ed = window?.delegate as? ImageEditor
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if e.modifierFlags.contains(.command) {
            if chars == "z" { undo(); return }
            if chars == "c" { ed?.copyAndClose(); return }
            if chars == "w" { window?.close(); return }
        }
        switch e.keyCode {
        case 53: window?.close(); return                     // Escape
        case 36, 76: ed?.copyAndClose(); return              // Return
        case 51, 117: undo(); return                         // Delete removes the last mark
        default: break
        }
        let tools: [String: Markup.Kind] = ["a": .arrow, "b": .box, "t": .text, "p": .pen, "h": .highlight, "r": .redact, "m": .mosaic]
        if let k = tools[chars] { ed?.selectTool(k); return }
        if let n = Int(chars), n >= 1, n <= PastelColor.allCases.count { ed?.selectColor(PastelColor.allCases[n - 1]); return }
        super.keyDown(with: e)
    }
}
