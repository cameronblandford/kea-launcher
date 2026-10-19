import AppKit
import LauncherCore

/// `paint` opens a small drawing window in the style of MS Paint, for a quick sketch.
/// Tools: pencil, eraser, fill, line, rectangle, ellipse, and a color picker, in four
/// sizes. Keys: P E F L R O I pick a tool, 1–4 the size, Shift keeps a line at 45° or a
/// shape square, Option fills a shape. Return copies the drawing and closes. Cmd+Z undo, Cmd+Shift+Z
/// redo, Cmd+C copy, Cmd+V paste an image, Cmd+S save, Cmd+N new, Escape closes. The drawing is kept in
/// `~/.launcher/paint.png`, so `paint` shows it again.
final class PaintWindow: NSObject, NSWindowDelegate {
    static let keywords: Set<String> = ["paint", "doodle"]
    static let file = Paths.root.appendingPathComponent("paint.png")
    private static var shared: PaintWindow?

    /// The 20 colors of the classic Paint palette, dark row then light row.
    static let palette: [UInt32] = [0x000000, 0x7F7F7F, 0x880015, 0xED1C24, 0xFF7F27, 0xFFF200, 0x22B14C, 0x00A2E8, 0x3F48CC, 0xA349A4,
                                    0xFFFFFF, 0xC3C3C3, 0xB97A57, 0xFFAEC9, 0xFFC90E, 0xEFE4B0, 0xB5E61D, 0x99D9EA, 0x7092BE, 0xC8BFE7]
    private static let toolInfo: [(PaintCanvas.Tool, symbol: String, name: String)] = [
        (.pencil, "pencil", "Pencil (P)"), (.eraser, "eraser", "Eraser (E)"), (.fill, "drop.fill", "Fill (F)"),
        (.line, "line.diagonal", "Line (L)"), (.rectangle, "rectangle", "Rectangle (R)"), (.ellipse, "circle", "Ellipse (O)"),
        (.picker, "eyedropper", "Pick a color (I)"),
    ]

    private let window: NSWindow
    private let canvas: PaintCanvas
    private let tools = NSSegmentedControl()
    private let sizes = NSSegmentedControl()
    private let well = NSColorWell()
    private let status = NSTextField(labelWithString: "")
    private let persist: Bool
    private var pendingSave: DispatchWorkItem?

    static func show(pasteClipboard: Bool = false) {
        let w = shared ?? PaintWindow()
        shared = w
        NSApp.activate(ignoringOtherApps: true)
        w.window.makeKeyAndOrderFront(nil)
        w.window.makeFirstResponder(w.canvas)
        if pasteClipboard { w.canvas.paste() }
    }

    /// Opens Paint with a picture on the canvas (a screenshot from `shot`).
    static func show(image: CGImage) {
        show()
        shared?.canvas.place(image)
    }

    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func results() -> [Result] {
        let icon = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        let saved = FileManager.default.fileExists(atPath: file.path)
        var rows = [Result(id: "paint:open", title: saved ? "Continue Your Drawing" : "Open Paint",
                           subtitle: "pencil, eraser, fill, line, rectangle, ellipse · Return copies and closes, Cmd+S saves, Cmd+N starts a new one",
                           icon: icon, action: .custom { show() })]
        if ImageEditor.clipboardImage() != nil {
            rows.append(Result(id: "paint:paste", title: "Paint on the Clipboard Image", subtitle: "Puts the image on the canvas; Cmd+Z takes it off",
                               icon: NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil),
                               action: .custom { show(pasteClipboard: true) }))
        }
        return rows
    }

    static var command: KeaCommand {
        KeaCommand(id: "paint", name: "Paint", keywords: keywords,
                   help: [.init(keyword: "paint", summary: "A small drawing window like MS Paint; the drawing is kept", example: "paint")],
                   results: { _ in results() })
    }

    /// `Kea --paint-snapshot out.png`: draws a sample with every tool and writes the
    /// window's content to a PNG. It does not read or write the saved drawing.
    static func snapshot(to url: URL) {
        let w = PaintWindow(persist: false)
        w.canvas.drawSample()
        w.canvas.tool = .ellipse
        w.refresh()
        guard let content = w.window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private init(persist: Bool = true) {
        self.persist = persist
        let saved = persist ? NSImage(contentsOf: Self.file)?.cgImage(forProposedRect: nil, context: nil, hints: nil) : nil
        canvas = PaintCanvas(image: saved)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PaintCanvas.size.width + 32, height: PaintCanvas.size.height + 132),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Paint"
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
        canvas.onChange = { [weak self] in self?.refresh() }
        canvas.onDraw = { [weak self] in self?.scheduleSave() }
        canvas.copyAction = { [weak self] in self?.copyPicture() }
        canvas.saveAction = { [weak self] in self?.saveAs() }
        canvas.doneAction = { [weak self] in self?.copyAndClose() }
        refresh()
        window.center()
        window.setFrameAutosaveName("Paint")
    }

    private func build() {
        guard let content = window.contentView else { return }
        tools.segmentCount = Self.toolInfo.count
        tools.trackingMode = .selectOne
        for (i, t) in Self.toolInfo.enumerated() {
            tools.setImage(NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.name), forSegment: i)
            tools.setToolTip(t.name, forSegment: i)
            tools.setWidth(38, forSegment: i)
        }
        tools.target = self
        tools.action = #selector(toolChanged)

        sizes.segmentCount = PaintCanvas.widths.count
        sizes.trackingMode = .selectOne
        for (i, w) in PaintCanvas.widths.enumerated() {
            let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Size \(i + 1)")?
                .withSymbolConfiguration(.init(pointSize: 5 + CGFloat(i) * 3.5, weight: .regular))
            sizes.setImage(dot, forSegment: i)
            sizes.setToolTip("\(Int(w)) points (\(i + 1))", forSegment: i)
            sizes.setWidth(34, forSegment: i)
        }
        sizes.target = self
        sizes.action = #selector(sizeChanged)

        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.toolTip = tip
            return b
        }
        let bar = NSStackView(views: [tools, sizes, NSView(),
                                      button("arrow.uturn.backward", "Undo (Cmd+Z)", #selector(undo)),
                                      button("arrow.uturn.forward", "Redo (Cmd+Shift+Z)", #selector(redo)),
                                      NSButton(title: "New", target: self, action: #selector(clear)),
                                      NSButton(title: "Save…", target: self, action: #selector(saveAs)),
                                      NSButton(title: "Copy", target: self, action: #selector(copyPicture))])
        bar.spacing = 10

        well.colorWellStyle = .minimal
        well.target = self
        well.action = #selector(wellChanged)
        well.toolTip = "The color in use; click for any color"
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.spacing = 3
        for row in 0 ..< 2 {
            let line = NSStackView()
            line.spacing = 3
            for column in 0 ..< 10 {
                let index = row * 10 + column
                let b = NSButton(frame: .zero)
                b.title = ""
                b.isBordered = false
                b.wantsLayer = true
                b.layer?.cornerRadius = 3
                b.layer?.borderWidth = 1
                b.layer?.borderColor = NSColor.separatorColor.cgColor
                b.layer?.backgroundColor = Self.color(Self.palette[index]).cgColor
                b.tag = index
                b.target = self
                b.action = #selector(swatchChosen(_:))
                b.widthAnchor.constraint(equalToConstant: 22).isActive = true
                b.heightAnchor.constraint(equalToConstant: 18).isActive = true
                line.addArrangedSubview(b)
            }
            rows.addArrangedSubview(line)
        }
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [well, rows, status])
        footer.spacing = 12

        canvas.wantsLayer = true
        canvas.layer?.borderWidth = 1
        canvas.layer?.borderColor = NSColor.separatorColor.cgColor
        for v in [bar, canvas, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            canvas.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
            canvas.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            canvas.widthAnchor.constraint(equalToConstant: PaintCanvas.size.width),
            canvas.heightAnchor.constraint(equalToConstant: PaintCanvas.size.height),
            footer.topAnchor.constraint(equalTo: canvas.bottomAnchor, constant: 12),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            well.widthAnchor.constraint(equalToConstant: 40),
            well.heightAnchor.constraint(equalToConstant: 39),
        ])
    }

    /// Shows the canvas state (tool, size, color) in the controls. Keys change it too.
    private func refresh() {
        tools.selectedSegment = Self.toolInfo.firstIndex { $0.0 == canvas.tool } ?? 0
        sizes.selectedSegment = canvas.sizeIndex
        well.color = canvas.color
        let name = Self.toolInfo.first { $0.0 == canvas.tool }?.name ?? ""
        status.stringValue = "\(name) · Shift keeps it straight or square · Option fills a shape · Cmd+Z undo · Return copies and closes"
    }

    // MARK: Actions

    @objc private func toolChanged() { canvas.tool = Self.toolInfo[tools.selectedSegment].0; refocus() }
    @objc private func sizeChanged() { canvas.sizeIndex = sizes.selectedSegment; refocus() }
    @objc private func swatchChosen(_ b: NSButton) { canvas.color = Self.color(Self.palette[b.tag]); refocus() }
    @objc private func wellChanged() { canvas.color = well.color }
    @objc private func undo() { canvas.undo(); refocus() }
    @objc private func redo() { canvas.redo(); refocus() }
    @objc private func clear() { canvas.clear(); refocus() }

    /// A click on a control must not take the keys away from the canvas.
    private func refocus() {
        refresh()
        window.makeFirstResponder(canvas)
    }

    @objc private func copyPicture() {
        guard let data = canvas.png() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        if let tiff = NSImage(data: data)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        status.stringValue = "Copied the drawing"
        refocusOnly()
    }

    /// Return: the drawing goes to the clipboard and the window closes, as in `ie`.
    private func copyAndClose() {
        copyPicture()
        Log.write("paint: copied the drawing and closed")
        window.close()
    }

    private func refocusOnly() { window.makeFirstResponder(canvas) }

    @objc private func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "Drawing \(f.string(from: Date())).png"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let data = self?.canvas.png() else { return }
            try? data.write(to: url)
            self?.refocusOnly()
        }
    }

    // MARK: The saved drawing

    private func scheduleSave() {
        guard persist else { return }
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard persist, canvas.changed, let data = canvas.png() else { return }
        canvas.changed = false
        DispatchQueue.global(qos: .utility).async { try? data.write(to: Self.file, options: .atomic) }
    }

    /// The undo history is large, so the window is dropped when it closes; the drawing is on disk.
    func windowWillClose(_ notification: Notification) {
        saveNow()
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
        well.deactivate()
        Self.shared = nil
    }
}

/// The drawing: a bitmap of 2 pixels a point. Every change draws into the bitmap; a shape
/// that is still dragged is drawn over the view and goes into the bitmap on mouse up.
final class PaintCanvas: NSView {
    enum Tool { case pencil, eraser, fill, line, rectangle, ellipse, picker }

    static let size = NSSize(width: 960, height: 640)
    /// Line widths in points for sizes 1 to 4. The eraser is twice as wide.
    static let widths: [CGFloat] = [2, 5, 10, 20]
    private static let scale: CGFloat = 2
    private static let undoLimit = 20

    var tool = Tool.pencil { didSet { if tool != .picker { toolBeforePicker = tool }; needsDisplay = true } }
    var color = NSColor.black
    var sizeIndex = 1 { didSet { needsDisplay = true } }
    /// The tool, size, or color changed, or the undo history did.
    var onChange: (() -> Void)?
    /// The picture changed.
    var onDraw: (() -> Void)?
    var copyAction: (() -> Void)?
    var saveAction: (() -> Void)?
    var doneAction: (() -> Void)?
    /// The picture differs from the saved file.
    var changed = false

    private let context: CGContext
    private var undoStack: [CGImage] = []
    private var redoStack: [CGImage] = []
    private var toolBeforePicker = Tool.pencil
    /// A freehand stroke in progress: the smoothed pen position, and the end of the curve
    /// drawn so far (the middle of the last two pen positions).
    private var last: NSPoint?
    private var strokeEnd: NSPoint?
    /// How far the pen moves toward the pointer on each event. Below 1 it takes the shake
    /// out of a line; much lower and the pen would lag behind the hand.
    private static let follow: CGFloat = 0.6
    private var start: NSPoint?
    private var current: NSPoint?
    private var filled = false
    private var hover: NSPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }

    private var pixelWidth: Int { context.width }
    private var pixelHeight: Int { context.height }
    private var full: CGRect { CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight) }

    init(image: CGImage?) {
        context = CGContext(data: nil, width: Int(Self.size.width * Self.scale), height: Int(Self.size.height * Self.scale),
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        context.setFillColor(.white)
        context.fill(full)
        if let image { context.draw(image, in: fit(image)) }
        context.setLineCap(.round)
        context.setLineJoin(.round)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A view point as a bitmap point. The bitmap's y axis goes up.
    private func pixel(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x * Self.scale, y: (Self.size.height - p.y) * Self.scale)
    }

    /// The largest centered rectangle for an image that is not made larger than its pixels.
    private func fit(_ image: CGImage) -> CGRect {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let k = min(1, CGFloat(pixelWidth) / w, CGFloat(pixelHeight) / h)
        return CGRect(x: (CGFloat(pixelWidth) - w * k) / 2, y: (CGFloat(pixelHeight) - h * k) / 2, width: w * k, height: h * k)
    }

    private var lineWidth: CGFloat { Self.widths[sizeIndex] * (tool == .eraser ? 2 : 1) }

    // MARK: - Changes

    private func remember() {
        guard let image = context.makeImage() else { return }
        undoStack.append(image)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func didDraw() {
        changed = true
        needsDisplay = true
        onDraw?()
    }

    private func restore(_ image: CGImage) {
        context.saveGState()
        context.setBlendMode(.copy)
        context.draw(image, in: full)
        context.restoreGState()
        didDraw()
        onChange?()
    }

    func undo() {
        guard let image = undoStack.popLast(), let now = context.makeImage() else { return NSSound.beep() }
        redoStack.append(now)
        restore(image)
    }

    func redo() {
        guard let image = redoStack.popLast(), let now = context.makeImage() else { return NSSound.beep() }
        undoStack.append(now)
        restore(image)
    }

    func clear() {
        remember()
        context.setFillColor(.white)
        context.fill(full)
        didDraw()
    }

    /// Puts the clipboard image in the middle of the canvas.
    func paste() {
        guard let image = NSImage(pasteboard: .general)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return NSSound.beep() }
        place(image)
    }

    /// Puts a picture in the middle of the canvas, made smaller when it does not fit.
    func place(_ image: CGImage) {
        remember()
        context.draw(image, in: fit(image))
        didDraw()
        onChange?()
    }

    func png() -> Data? {
        context.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }

    private func segment(from a: NSPoint, to b: NSPoint) {
        context.setStrokeColor(tool == .eraser ? .white : color.cgColor)
        context.setLineWidth(lineWidth * Self.scale)
        context.move(to: pixel(a))
        context.addLine(to: pixel(b))
        context.strokePath()
        didDraw()
    }

    /// One piece of a freehand stroke: a curve that bends at `control`. Pieces that meet at
    /// the middle of two pen positions join without a corner.
    private func curve(from a: NSPoint, control: NSPoint, to b: NSPoint) {
        context.setStrokeColor(tool == .eraser ? .white : color.cgColor)
        context.setLineWidth(lineWidth * Self.scale)
        context.move(to: pixel(a))
        context.addQuadCurve(to: pixel(b), control: pixel(control))
        context.strokePath()
        didDraw()
    }

    private func shape(_ kind: Tool, from a: NSPoint, to b: NSPoint, filled: Bool) {
        let p = pixel(a), q = pixel(b)
        let rect = CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y))
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(lineWidth * Self.scale)
        switch kind {
        case .line:
            context.move(to: p)
            context.addLine(to: q)
        case .rectangle: context.addRect(rect)
        default: context.addEllipse(in: rect)
        }
        context.drawPath(using: filled && kind != .line ? .fillStroke : .stroke)
        didDraw()
    }

    private func bucket(at point: NSPoint) {
        guard let data = context.data, let rgb = color.usingColorSpace(.sRGB) else { return }
        let x = Int(point.x * Self.scale), y = Int(point.y * Self.scale)
        // The first row of the bitmap's memory is the top row of the picture.
        PaintFill.fill(data.assumingMemoryBound(to: UInt8.self), width: pixelWidth, height: pixelHeight, bytesPerRow: context.bytesPerRow,
                       x: x, y: y, color: (UInt8(rgb.redComponent * 255), UInt8(rgb.greenComponent * 255), UInt8(rgb.blueComponent * 255)))
        didDraw()
    }

    private func pick(at point: NSPoint) {
        guard let data = context.data else { return }
        let x = min(max(Int(point.x * Self.scale), 0), pixelWidth - 1), y = min(max(Int(point.y * Self.scale), 0), pixelHeight - 1)
        let p = data.assumingMemoryBound(to: UInt8.self) + y * context.bytesPerRow + x * 4
        color = NSColor(srgbRed: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255, blue: CGFloat(p[2]) / 255, alpha: 1)
        onChange?()
    }

    /// With Shift: a line at a multiple of 45°, or a shape with equal sides.
    private func constrained(_ p: NSPoint, from a: NSPoint, shift: Bool) -> NSPoint {
        guard shift else { return p }
        let dx = p.x - a.x, dy = p.y - a.y
        if tool == .line {
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return NSPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
        }
        let side = max(abs(dx), abs(dy))
        return NSPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side))
    }

    /// For `--paint-snapshot`: something from every tool.
    func drawSample() {
        func c(_ i: Int) -> NSColor { PaintWindow.color(PaintWindow.palette[i]) }
        sizeIndex = 1
        tool = .pencil
        color = c(0)
        var previous = NSPoint(x: 60, y: 200)
        for i in 1 ... 60 {
            let p = NSPoint(x: 60 + CGFloat(i) * 5, y: 200 + sin(CGFloat(i) / 5) * 60)
            segment(from: previous, to: p)
            previous = p
        }
        color = c(8)
        shape(.rectangle, from: NSPoint(x: 420, y: 80), to: NSPoint(x: 640, y: 260), filled: false)
        color = c(3)
        shape(.ellipse, from: NSPoint(x: 700, y: 80), to: NSPoint(x: 900, y: 260), filled: false)
        color = c(5)
        bucket(at: NSPoint(x: 800, y: 170))
        color = c(17)
        bucket(at: NSPoint(x: 530, y: 170))
        sizeIndex = 3
        color = c(6)
        shape(.line, from: NSPoint(x: 80, y: 420), to: NSPoint(x: 400, y: 560), filled: false)
        sizeIndex = 2
        color = c(9)
        shape(.ellipse, from: NSPoint(x: 480, y: 360), to: NSPoint(x: 700, y: 580), filled: true)
        tool = .eraser
        segment(from: NSPoint(x: 500, y: 470), to: NSPoint(x: 680, y: 470))
        // A shaky hand: the same zigzag as plain segments (top) and through the smoothing (bottom).
        tool = .pencil
        sizeIndex = 0
        color = c(0)
        let shaky = (0 ... 40).map { i in NSPoint(x: 740 + CGFloat(i) * 4.5, y: 400 + sin(CGFloat(i) / 6) * 30 + (i % 2 == 0 ? 3 : -3)) }
        for (a, b) in zip(shaky, shaky.dropFirst()) { segment(from: a, to: b) }
        var pen = NSPoint(x: shaky[0].x, y: shaky[0].y + 110), end = pen
        for point in shaky.dropFirst() {
            let p = NSPoint(x: point.x, y: point.y + 110)
            let next = NSPoint(x: pen.x + (p.x - pen.x) * Self.follow, y: pen.y + (p.y - pen.y) * Self.follow)
            let middle = NSPoint(x: (pen.x + next.x) / 2, y: (pen.y + next.y) / 2)
            curve(from: end, control: pen, to: middle)
            pen = next
            end = middle
        }
        sizeIndex = 1
        pick(at: NSPoint(x: 800, y: 170))
    }

    // MARK: - Drawing the view

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        if let image = context.makeImage() {
            cg.saveGState()
            cg.translateBy(x: 0, y: bounds.height)
            cg.scaleBy(x: 1, y: -1)
            cg.draw(image, in: CGRect(origin: .zero, size: bounds.size))
            cg.restoreGState()
        }
        if let start, let current {
            // The shape in progress, as it will look in the bitmap.
            let rect = NSRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(start.x - current.x), height: abs(start.y - current.y))
            let path: NSBezierPath
            switch tool {
            case .line:
                path = NSBezierPath()
                path.move(to: start)
                path.line(to: current)
            case .rectangle: path = NSBezierPath(rect: rect)
            default: path = NSBezierPath(ovalIn: rect)
            }
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.set()
            if filled, tool != .line { path.fill() }
            path.stroke()
        } else if let hover, tool == .pencil || tool == .eraser {
            // The size of the tip, so the first stroke is no surprise.
            let ring = NSBezierPath(ovalIn: NSRect(x: hover.x - lineWidth / 2, y: hover.y - lineWidth / 2, width: lineWidth, height: lineWidth))
            ring.lineWidth = 1
            NSColor.black.withAlphaComponent(0.5).setStroke()
            ring.stroke()
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        hover = convert(event.locationInWindow, from: nil)
        if tool == .pencil || tool == .eraser { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        hover = nil
        switch tool {
        case .pencil, .eraser:
            remember()
            last = p
            strokeEnd = p
            segment(from: p, to: p)
        case .fill:
            remember()
            bucket(at: p)
        case .picker:
            pick(at: p)
        case .line, .rectangle, .ellipse:
            start = p
            current = p
            filled = event.modifierFlags.contains(.option)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch tool {
        case .pencil, .eraser:
            guard let last, let strokeEnd else { return }
            let pen = NSPoint(x: last.x + (p.x - last.x) * Self.follow, y: last.y + (p.y - last.y) * Self.follow)
            let middle = NSPoint(x: (last.x + pen.x) / 2, y: (last.y + pen.y) / 2)
            curve(from: strokeEnd, control: last, to: middle)
            self.last = pen
            self.strokeEnd = middle
        case .picker:
            pick(at: p)
        case .line, .rectangle, .ellipse:
            guard let start else { return }
            current = constrained(p, from: start, shift: event.modifierFlags.contains(.shift))
            filled = event.modifierFlags.contains(.option)
            needsDisplay = true
        case .fill:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let start, let current {
            // A click without a drag draws nothing.
            if hypot(current.x - start.x, current.y - start.y) >= 1 {
                remember()
                shape(tool, from: start, to: current, filled: filled)
            }
        }
        if let last, let strokeEnd {
            // The pen is a little behind the pointer; the stroke ends where the pointer is.
            curve(from: strokeEnd, control: last, to: convert(event.locationInWindow, from: nil))
        }
        start = nil
        current = nil
        last = nil
        strokeEnd = nil
        hover = convert(event.locationInWindow, from: nil)
        // The picker is for one color; then the tool from before comes back.
        if tool == .picker { tool = toolBeforePicker }
        needsDisplay = true
        onChange?()
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command), shift = event.modifierFlags.contains(.shift)
        if command {
            switch event.keyCode {
            case 6: shift ? redo() : undo()          // Z
            case 8: copyAction?()                    // C
            case 9: paste()                          // V
            case 1: saveAction?()                    // S
            case 45: clear()                         // N
            case 13: window?.performClose(nil)       // W
            default: super.keyDown(with: event)
            }
            onChange?()
            return
        }
        switch event.keyCode {
        case 53: window?.performClose(nil)           // Escape
        case 36, 76: return doneAction?() ?? ()      // Return
        case 35: tool = .pencil                      // P
        case 14: tool = .eraser                      // E
        case 3: tool = .fill                         // F
        case 37: tool = .line                        // L
        case 15: tool = .rectangle                   // R
        case 31: tool = .ellipse                     // O
        case 34: tool = .picker                      // I
        case 18, 19, 20, 21: sizeIndex = [18: 0, 19: 1, 20: 2, 21: 3][event.keyCode] ?? sizeIndex    // 1 to 4
        default: return super.keyDown(with: event)
        }
        onChange?()
    }
}
