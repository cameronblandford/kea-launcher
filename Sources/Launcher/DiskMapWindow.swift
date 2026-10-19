import AppKit
import LauncherCore
import Quartz

/// `du` opens a treemap of the disk, like WinDirStat: each file is a block, the area is
/// its size on disk, the color is its type, and the shading shows the folders. `du` maps
/// the whole data volume (accurate only with Full Disk Access); `du <path>` maps a folder.
///
/// Click selects a file, and another click on the same block selects the folder above it.
/// Return or a double-click zooms in, Delete zooms out, Space previews, Cmd+R reveals in
/// Finder, Cmd+C copies the path, Cmd+Delete moves to the Trash, R scans again, Escape closes.
/// L lists the large files that were not opened for six months. What is in the Trash has
/// its own color.
final class DiskMapWindow: NSObject, NSWindowDelegate {
    static let keywords: Set<String> = ["du"]
    /// The volume with the user's files. `/` is the sealed system volume, which only links to it.
    static let dataVolume = "/System/Volumes/Data"
    private static let fullDiskAccessPane = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    private static var shared: DiskMapWindow?

    private let window: NSWindow
    private let view = DiskMapView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760))

    static func show(path: String) {
        let w = shared ?? DiskMapWindow()
        shared = w
        NSApp.activate(ignoringOtherApps: true)
        w.window.makeKeyAndOrderFront(nil)
        w.window.makeFirstResponder(w.view)
        w.view.open(path)
    }

    /// Kea can read the privacy database only when it has Full Disk Access. The check
    /// does not make macOS ask for anything.
    static var hasFullDiskAccess: Bool {
        let fd = open(Paths.home.path + "/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    static func volume() -> (name: String, used: Int64, free: Int64) {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let total = Int64(values?.volumeTotalCapacity ?? 0), free = Int64(values?.volumeAvailableCapacity ?? 0)
        return (values?.volumeLocalizedName ?? "the disk", total - free, free)
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func results(argument: String) -> [Result] {
        let icon = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)
        let keys = "click selects, Return zooms in, Delete zooms out, Cmd+Delete moves to the Trash"
        let arg = argument.trimmingCharacters(in: .whitespaces)
        if arg.isEmpty || arg == "/" {
            let v = volume()
            let space = "\(bytes(v.used)) used, \(bytes(v.free)) free"
            let map = { show(path: dataVolume) }
            if hasFullDiskAccess {
                return [Result(id: "diskmap:volume", title: "Map \(v.name)", subtitle: "\(space) · \(keys)", icon: icon, action: .custom(map), keyword: "disk map")]
            }
            return [
                Result(id: "diskmap:grant", title: "Grant Full Disk Access to Kea",
                       subtitle: "Opens System Settings: add Kea to the list, then restart Kea. Without it, protected folders count as empty",
                       icon: NSImage(systemSymbolName: "lock.open", accessibilityDescription: nil),
                       action: .custom { NSWorkspace.shared.open(URL(string: fullDiskAccessPane)!) }),
                Result(id: "diskmap:volume", title: "Map \(v.name) without full access",
                       subtitle: "\(space) · the total will be too small", icon: icon, action: .custom(map), keyword: "disk map"),
            ]
        }
        let path = (Paths.expand(arg) as NSString).standardizingPath
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
            return [Result(id: "diskmap:error", title: "Could not read \(arg)", subtitle: "Give a folder, for example: du ~/Downloads",
                           icon: icon, action: .none)]
        }
        return [Result(id: "diskmap:path", title: "Map \((path as NSString).abbreviatingWithTildeInPath)", subtitle: keys,
                       icon: icon, action: .custom { show(path: path) }, revealPath: path)]
    }

    static var command: KeaCommand {
        KeaCommand(id: "diskmap", name: "Disk Map", keywords: keywords,
                   help: [.init(keyword: "du", summary: "Map of what uses the disk: each file is a block, the area is its size", example: "du ~/Downloads")],
                   search: { term, _ in
                       // `disk` must still find Disk Utility, so it is not a keyword.
                       "disk map".hasPrefix(term.lowercased()) && term.count >= 4 ? results(argument: "").filter { $0.id == "diskmap:volume" } : []
                   },
                   results: { ctx in results(argument: ctx.argument) })
    }

    /// `Kea --diskmap-snapshot <folder> out.png`: scans the folder, prints the counts and
    /// the time, and writes the window's content to a PNG. It does not touch the running app.
    static func snapshot(path: String, to url: URL) {
        let root = (Paths.expand(path) as NSString).standardizingPath
        let started = Date()
        guard let tree = DiskScanner(root: root == "/" ? dataVolume : root).run() else {
            print("could not read \(path)")
            return
        }
        print(String(format: "%d files, %d nodes, %@, %d folders not readable, %.2f s",
                     tree.fileCount, tree.count, bytes(Int64(tree.size[0])), tree.deniedCount, Date().timeIntervalSince(started)))
        let view = DiskMapView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        let drawn = Date()
        view.showSample(tree, free: ProcessInfo.processInfo.environment["KEA_DISKMAP_FREE"].flatMap(UInt64.init) ?? 0)
        print(String(format: "layout and drawing: %.2f s, %d blocks", Date().timeIntervalSince(drawn), view.blockCount))
        func write(_ url: URL) {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        write(url)
        // out-old.png: the same map with the list of large files not opened for a long time.
        view.sampleOldFiles()
        write(URL(fileURLWithPath: url.deletingPathExtension().path + "-old.png"))
        // A second picture, zoomed into the folder of the largest file: out-zoom.png.
        view.sampleZoom()
        write(URL(fileURLWithPath: url.deletingPathExtension().path + "-zoom.png"))
    }

    private override init() {
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Disk Map"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = view
        window.contentMinSize = NSSize(width: 520, height: 360)
        window.center()
        window.setFrameAutosaveName("DiskMap")
    }

    /// The tree of a whole disk is large, so it is dropped when the window closes.
    func windowWillClose(_ notification: Notification) { view.close() }
}

private final class DiskMapView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private static let barHeight: CGFloat = 28
    private static let rowHeight: CGFloat = 24
    /// The 12 file types that use the most space get these, largest first.
    private static let palette: [UInt32] = [0x4E79A7, 0xF28E2B, 0xE15759, 0x76B7B2, 0x59A14F, 0xEDC948,
                                            0xB07AA1, 0xFF9DA7, 0x9C755F, 0x5FA2CE, 0xC85200, 0x8CD17D]
    private static let otherColor: UInt32 = 0xA9A9AE
    private static let folderColor: UInt32 = 0x8E8E93
    private static let smallColor: UInt32 = 0x6E6E73
    private static let trashColor: UInt32 = 0x8A4B3C
    private static let oldAge: TimeInterval = 180 * 86400
    /// The free-space block: light in a light window, dark in a dark one.
    private static let freeColor: (light: UInt32, dark: UInt32) = (0xE9E9ED, 0x3C3C40)

    private var target = ""
    private var scanner: DiskScanner?
    private var tree: DiskTree?
    private var failure: String?
    /// A one-time note in the status line (the result of a Trash move).
    private var message: String?
    private var zoom: Int32 = 0
    private var selection: Int32?
    private var lastClicked: Int32?
    private var hover: Int?
    private var layout: TreemapLayout?
    private var image: CGImage?
    private var generation = 0
    /// For each extension id: 1 + its index in the palette, or 0.
    private var paletteIndex: [UInt8] = []
    private var legend: [(name: String, bytes: UInt64, color: UInt32)] = []
    private var crumbs: [(node: Int32, rect: NSRect)] = []
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var volume = DiskMapWindow.volume()
    /// The Trash folders in the scan; what is in them is drawn in its own color.
    private var trashNodes: [Int32] = []
    /// The list of large files that were not opened for a long time (the L key).
    private var showOld = false
    private var oldFiles: [(node: Int32, opened: Date)]?
    private var oldRows: [(node: Int32, rect: NSRect)] = []
    private var oldHover: Int32?
    private var oldGeneration = 0
    /// Layout, drawing, and changes to the tree run here one at a time.
    private let work = DispatchQueue(label: "directory.kea.launcher.diskmap", qos: .userInitiated)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var blockCount: Int { layout?.cells.count ?? 0 }

    private var mapRect: NSRect {
        NSRect(x: 0, y: Self.barHeight, width: bounds.width, height: max(0, bounds.height - Self.barHeight - 2 * Self.rowHeight))
    }
    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
    private var wholeVolume: Bool { target == DiskMapWindow.dataVolume }
    /// Free space is a block only on the map of the whole disk, and only at the top level.
    private var shownFree: UInt64 { wholeVolume && zoom == 0 ? UInt64(max(0, volume.free)) : 0 }
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    // MARK: - Scan

    /// Shows the map of `path`. A map of the same folder that is on screen stays; R scans again.
    func open(_ path: String) {
        if path == target, scanner != nil || tree != nil { return }
        start(path)
    }

    private func start(_ path: String) {
        close()
        target = path
        failure = nil
        message = nil
        volume = DiskMapWindow.volume()
        let scanner = DiskScanner(root: path)
        self.scanner = scanner
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.needsDisplay = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            let tree = scanner.run()
            Log.write("diskmap: \(path): \(tree?.fileCount ?? 0) files in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanner === scanner, !scanner.isCancelled else { return }
                self.finish(tree)
            }
        }
        needsDisplay = true
    }

    /// Stops a scan and frees the tree.
    func close() {
        scanner?.cancel()
        scanner = nil
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        generation += 1
        tree = nil
        layout = nil
        image = nil
        zoom = 0
        selection = nil
        lastClicked = nil
        hover = nil
        trashNodes = []
        showOld = false
        oldFiles = nil
        oldRows = []
        target = ""
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
    }

    private func finish(_ tree: DiskTree?) {
        scanner = nil
        timer?.invalidate()
        timer = nil
        guard let tree else {
            failure = "Could not read \(displayRoot)"
            needsDisplay = true
            return
        }
        adopt(tree)
        relayout()
    }

    private func adopt(_ tree: DiskTree) {
        self.tree = tree
        paletteIndex = [UInt8](repeating: 0, count: tree.extensions.count)
        legend = []
        var other: UInt64 = 0
        for total in tree.extensionTotals() {
            if total.ext != 0, legend.count < Self.palette.count {
                paletteIndex[Int(total.ext)] = UInt8(legend.count + 1)
                legend.append(("." + tree.extensions[Int(total.ext)], total.bytes, Self.palette[legend.count]))
            } else {
                other += total.bytes
            }
        }
        if other > 0 { legend.append(("other", other, Self.otherColor)) }
        // The Trash of the scanned folder, or of each user on a whole disk.
        func child(_ parent: Int32, _ name: String) -> Int32? { tree.children(of: parent).first { tree.name(of: $0) == name } }
        var trash = [child(0, ".Trash")].compactMap { $0 }
        if let users = child(0, "Users") { trash += tree.children(of: users).compactMap { child($0, ".Trash") } }
        trashNodes = trash.filter { tree.size[Int($0)] > 0 }
        let trashBytes = trashNodes.reduce(UInt64(0)) { $0 + tree.size[Int($1)] }
        if trashBytes > 0 { legend.insert(("Trash", trashBytes, Self.trashColor), at: 0) }
    }

    /// For `--diskmap-snapshot`: a finished map with the largest file selected, drawn at once.
    /// `free` (bytes) shows the tree as the map of a whole disk with that much free space.
    func showSample(_ tree: DiskTree, free: UInt64 = 0) {
        target = free > 0 ? DiskMapWindow.dataVolume : tree.rootPath
        if free > 0 { volume = (volume.name, Int64(tree.size[0]), Int64(free)) }
        adopt(tree)
        drawNow()
        selection = layout?.cells.filter { $0.kind == .file }.max { $0.w * $0.h < $1.w * $1.h }?.node
    }

    /// For `--diskmap-snapshot`: the same as Return, then a click on the largest block.
    /// For `--diskmap-snapshot`: the list of old files, loaded at once.
    func sampleOldFiles() {
        guard let tree else { return }
        showOld = true
        oldFiles = Self.oldFiles(tree, below: zoom)
        selection = oldFiles?.first?.node
    }

    func sampleZoom() {
        zoomIn()
        drawNow()
        selection = layout?.cells.max { $0.w * $0.h < $1.w * $1.h }?.node
    }

    private func drawNow() {
        guard let tree else { return }
        generation += 1
        let map = mapRect
        let drawn = Self.draw(tree, root: zoom, width: Int(map.width * scale), height: Int(map.height * scale), paletteIndex: paletteIndex,
                              free: shownFree, dark: isDark, trash: trashNodes)
        layout = drawn.layout
        image = drawn.image
    }

    // MARK: - Layout

    private func relayout() {
        pending?.cancel()
        guard let tree else { return }
        let map = mapRect
        let width = Int(map.width * scale), height = Int(map.height * scale)
        guard width > 0, height > 0 else { return }
        generation += 1
        let generation = generation, root = zoom, paletteIndex = paletteIndex, free = shownFree, dark = isDark, trash = trashNodes
        work.async { [weak self] in
            let drawn = Self.draw(tree, root: root, width: width, height: height, paletteIndex: paletteIndex, free: free, dark: dark, trash: trash)
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.layout = drawn.layout
                self.image = drawn.image
                self.hover = nil
                self.needsDisplay = true
            }
        }
    }

    /// `free` is the free space of the volume, or 0 to leave it out.
    private static func draw(_ tree: DiskTree, root: Int32, width: Int, height: Int, paletteIndex: [UInt8],
                             free: UInt64, dark: Bool, trash: [Int32]) -> (layout: TreemapLayout, image: CGImage?) {
        let layout = Treemap.layout(tree, root: root, width: width, height: height, free: free)
        let colors = layout.cells.map { cell -> UInt32 in
            if cell.kind != .free, trash.contains(where: { tree.isAncestor($0, of: cell.node) }) { return trashColor }
            switch cell.kind {
            case .small: return smallColor
            case .folder: return folderColor
            case .free: return dark ? freeColor.dark : freeColor.light
            case .file:
                let index = Int(paletteIndex[Int(tree.ext[Int(cell.node)])])
                return index == 0 ? otherColor : palette[index - 1]
            }
        }
        let pixels = Treemap.render(layout, colors: colors)
        let image = CGDataProvider(data: Data(pixels) as CFData).flatMap {
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        return (layout, image)
    }

    /// While the window changes size the old picture is stretched; the new one comes after a pause.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard tree != nil else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.relayout() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        relayout()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        relayout()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    /// The layout is in pixels of the picture; this is the same place in the view.
    private func viewRect(_ r: (x: Double, y: Double, w: Double, h: Double)) -> NSRect? {
        guard let layout, layout.width > 0, layout.height > 0 else { return nil }
        let map = mapRect
        let sx = map.width / CGFloat(layout.width), sy = map.height / CGFloat(layout.height)
        return NSRect(x: map.minX + CGFloat(r.x) * sx, y: map.minY + CGFloat(r.y) * sy, width: CGFloat(r.w) * sx, height: CGFloat(r.h) * sy)
    }

    private func cell(at point: NSPoint) -> Int? {
        let map = mapRect
        guard let layout, map.contains(point), map.width > 0, map.height > 0 else { return nil }
        return layout.cell(atX: Int((point.x - map.minX) / map.width * CGFloat(layout.width)),
                           y: Int((point.y - map.minY) / map.height * CGFloat(layout.height)))
    }

    // MARK: - Paths

    /// The path to act on. A scan of the data volume has paths below `/System/Volumes/Data`;
    /// the same file without that prefix is the path people know.
    private func path(of node: Int32) -> String? {
        guard let tree else { return nil }
        let full = tree.path(of: node)
        guard wholeVolume else { return full }
        let rest = String(full.dropFirst(DiskMapWindow.dataVolume.count))
        return rest.isEmpty ? "/" : rest
    }

    private func shortPath(of node: Int32) -> String {
        ((path(of: node) ?? "") as NSString).abbreviatingWithTildeInPath
    }

    private var displayRoot: String {
        wholeVolume ? volume.name : (target as NSString).abbreviatingWithTildeInPath
    }

    private var selectedPath: String? { selection.flatMap(path(of:)) }

    // MARK: - Drawing

    private func text(_ string: String, at point: NSPoint, color: NSColor = .labelColor, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                      maxWidth: CGFloat? = nil) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style]
        if let maxWidth {
            (string as NSString).draw(in: NSRect(x: point.x, y: point.y, width: maxWidth, height: size + 6), withAttributes: attributes)
        } else {
            (string as NSString).draw(at: point, withAttributes: attributes)
        }
    }

    private func width(_ string: String, size: CGFloat = 12, weight: NSFont.Weight = .regular) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }

    private func centered(_ title: String, _ detail: String) {
        let map = mapRect
        text(title, at: NSPoint(x: map.midX - width(title, size: 17, weight: .medium) / 2, y: map.midY - 22), size: 17, weight: .medium)
        let w = min(width(detail), map.width - 40)
        text(detail, at: NSPoint(x: map.midX - w / 2, y: map.midY + 6), color: .secondaryLabelColor, maxWidth: w + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        drawBar()
        let map = mapRect
        if let failure {
            centered(failure, "Press R to try again")
        } else if let scanner {
            let p = scanner.progress
            let files = NumberFormatter.localizedString(from: NSNumber(value: p.files), number: .decimal)
            centered("Scanning \(displayRoot): \(files) files, \(DiskMapWindow.bytes(Int64(p.bytes)))",
                     wholeVolume ? String(p.path.dropFirst(DiskMapWindow.dataVolume.count)) : p.path)
        } else if let image, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.translateBy(x: map.minX, y: map.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: map.width, height: map.height))
            context.restoreGState()
            if let hover, let layout, hover < layout.cells.count {
                let c = layout.cells[hover]
                outline(viewRect((c.x, c.y, c.w, c.h)), width: 1)
            }
            if let selection, let rect = layout?.rect(of: selection) { outline(viewRect(rect), width: 2) }
        } else if let tree, tree.size[Int(zoom)] == 0 {
            centered("Nothing here uses space", "Press Delete to go back")
        }
        drawLegend(y: map.maxY)
        drawStatus(y: map.maxY + Self.rowHeight)
        if showOld, tree != nil, scanner == nil { drawOldFiles(in: map) }
    }

    private func outline(_ rect: NSRect?, width: CGFloat) {
        guard let rect else { return }
        let outer = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        outer.lineWidth = width + 2
        NSColor.black.withAlphaComponent(0.7).setStroke()
        outer.stroke()
        let inner = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        inner.lineWidth = width
        NSColor.white.setStroke()
        inner.stroke()
    }

    /// The folders from the scan root to the zoomed one; each is a button.
    private func drawBar() {
        crumbs = []
        var x: CGFloat = 12
        var chain: [Int32] = []
        if let tree {
            var n = zoom
            while n >= 0 {
                chain.append(n)
                n = tree.parent[Int(n)]
            }
        } else {
            chain = [0]
        }
        for (i, node) in chain.reversed().enumerated() {
            let name = node == 0 ? displayRoot : tree?.name(of: node) ?? ""
            let last = i == chain.count - 1
            if i > 0 {
                text("›", at: NSPoint(x: x, y: 6), color: .tertiaryLabelColor, size: 13)
                x += 14
            }
            let w = width(name, size: 13, weight: last ? .semibold : .regular)
            text(name, at: NSPoint(x: x, y: 6), color: last ? .labelColor : .secondaryLabelColor, size: 13, weight: last ? .semibold : .regular)
            crumbs.append((node, NSRect(x: x - 4, y: 0, width: w + 8, height: Self.barHeight)))
            x += w + 8
        }
        let hint = "Return zooms in · Delete zooms out · Space previews · ⌘⌫ Trash · L old files · R scans again"
        let w = width(hint, size: 11)
        if tree != nil, bounds.width - w - 12 > x + 20 {
            text(hint, at: NSPoint(x: bounds.width - w - 12, y: 8), color: .tertiaryLabelColor, size: 11)
        }
    }

    private func drawLegend(y: CGFloat) {
        var x: CGFloat = 12
        for entry in legend {
            let label = "\(entry.name) \(DiskMapWindow.bytes(Int64(entry.bytes)))"
            let w = width(label, size: 11)
            guard x + 16 + w < bounds.width - 8 else { break }
            NSColor(srgbRed: CGFloat((entry.color >> 16) & 0xFF) / 255, green: CGFloat((entry.color >> 8) & 0xFF) / 255,
                    blue: CGFloat(entry.color & 0xFF) / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y + 7, width: 10, height: 10), xRadius: 2, yRadius: 2).fill()
            text(label, at: NSPoint(x: x + 14, y: y + 5), color: .secondaryLabelColor, size: 11)
            x += 14 + w + 14
        }
    }

    private func drawStatus(y: CGFloat) {
        guard let tree else { return }
        var right = ""
        if wholeVolume {
            let scanned = Int64(tree.size[0])
            right = "\(DiskMapWindow.bytes(volume.free)) free · scanned \(DiskMapWindow.bytes(scanned)) of \(DiskMapWindow.bytes(volume.used)) used"
            if volume.used > scanned { right += " · \(DiskMapWindow.bytes(volume.used - scanned)) snapshots, purgeable, system" }
        } else {
            right = "\(DiskMapWindow.bytes(Int64(tree.size[0]))) in \(NumberFormatter.localizedString(from: NSNumber(value: tree.fileCount), number: .decimal)) files"
        }
        if tree.deniedCount > 0 { right += " · \(tree.deniedCount) folders not readable" }
        let rightWidth = min(width(right, size: 11), bounds.width / 2)
        text(right, at: NSPoint(x: bounds.width - rightWidth - 12, y: y + 5), color: .secondaryLabelColor, size: 11, maxWidth: rightWidth + 2)

        var left = message ?? ""
        if left.isEmpty {
            var node = selection
            var small = false
            var free = false
            if node == nil, let hover, let layout, hover < layout.cells.count {
                free = layout.cells[hover].kind == .free
                node = free ? nil : layout.cells[hover].node
                small = layout.cells[hover].kind == .small
            }
            if free {
                left = "Free space — \(DiskMapWindow.bytes(volume.free))"
            } else if let node {
                let size = tree.size[Int(node)]
                let share = tree.size[Int(zoom)] > 0 ? Double(size) / Double(tree.size[Int(zoom)]) * 100 : 0
                left = small ? "Small items in \(shortPath(of: node))"
                    : "\(shortPath(of: node)) — \(DiskMapWindow.bytes(Int64(size))) · \(String(format: share < 10 ? "%.1f" : "%.0f", share))%"
            } else {
                left = "Click a block to select it"
            }
        }
        text(left, at: NSPoint(x: 12, y: y + 4), color: message == nil && selection == nil ? .secondaryLabelColor : .labelColor,
             maxWidth: bounds.width - rightWidth - 36)
    }

    // MARK: - Old files

    private var oldPanel: NSRect {
        let map = mapRect
        let width = min(440, map.width * 0.6)
        return NSRect(x: map.maxX - width, y: map.minY, width: width, height: map.height)
    }

    /// The largest files below `root` that nobody opened for six months. Reads the
    /// access date of the largest 400 files only. Runs on the work queue.
    private static func oldFiles(_ tree: DiskTree, below root: Int32) -> [(node: Int32, opened: Date)] {
        var large: [Int32] = []
        var stack = [root]
        while let folder = stack.popLast() {
            for child in tree.children(of: folder) where tree.size[Int(child)] > 0 {
                if tree.isDirectory(child) { stack.append(child) } else if tree.size[Int(child)] >= 100_000_000 { large.append(child) }
            }
        }
        large.sort { tree.size[Int($0)] > tree.size[Int($1)] }
        let cutoff = Date().addingTimeInterval(-oldAge)
        var out: [(Int32, Date)] = []
        for node in large.prefix(400) {
            let url = URL(fileURLWithPath: tree.path(of: node))
            guard let opened = try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate, opened < cutoff else { continue }
            out.append((node, opened))
            if out.count == 40 { break }
        }
        return out.map { (node: $0.0, opened: $0.1) }
    }

    private func loadOldFiles() {
        guard let tree, showOld else { return }
        oldFiles = nil
        oldGeneration += 1
        let generation = oldGeneration, root = zoom
        work.async { [weak self] in
            let found = Self.oldFiles(tree, below: root)
            DispatchQueue.main.async {
                guard let self, self.oldGeneration == generation else { return }
                self.oldFiles = found
                self.needsDisplay = true
            }
        }
        needsDisplay = true
    }

    private func drawOldFiles(in map: NSRect) {
        guard let tree else { return }
        let panel = oldPanel
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        panel.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: panel.minX, y: panel.minY, width: 1, height: panel.height).fill()
        text("Large files not opened for 6 months", at: NSPoint(x: panel.minX + 12, y: panel.minY + 8), weight: .semibold)
        text("L closes", at: NSPoint(x: panel.maxX - width("L closes", size: 11) - 12, y: panel.minY + 9), color: .tertiaryLabelColor, size: 11)
        oldRows = []
        guard let oldFiles else {
            return text("Looking…", at: NSPoint(x: panel.minX + 12, y: panel.minY + 36), color: .secondaryLabelColor)
        }
        if oldFiles.isEmpty {
            return text("None of 100 MB or more in this folder", at: NSPoint(x: panel.minX + 12, y: panel.minY + 36), color: .secondaryLabelColor)
        }
        let month = DateFormatter()
        month.dateFormat = "MMM yyyy"
        var y = panel.minY + 32
        for file in oldFiles where y + 38 <= panel.maxY {
            let row = NSRect(x: panel.minX + 1, y: y, width: panel.width - 1, height: 38)
            if file.node == selection {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).setFill()
                row.fill()
            } else if file.node == oldHover {
                NSColor.labelColor.withAlphaComponent(0.07).setFill()
                row.fill()
            }
            let size = DiskMapWindow.bytes(Int64(tree.size[Int(file.node)]))
            let sizeWidth = width(size)
            text(size, at: NSPoint(x: panel.maxX - sizeWidth - 12, y: y + 4), color: .secondaryLabelColor)
            text(tree.name(of: file.node), at: NSPoint(x: panel.minX + 12, y: y + 4), maxWidth: panel.width - sizeWidth - 36)
            text("\(shortPath(of: tree.parent[Int(file.node)])) · opened \(month.string(from: file.opened))", at: NSPoint(x: panel.minX + 12, y: y + 20),
                 color: .secondaryLabelColor, size: 11, maxWidth: panel.width - 24)
            oldRows.append((file.node, row))
            y += 38
        }
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if showOld, oldPanel.contains(point) {
            let row = oldRows.first { $0.rect.contains(point) }?.node
            if row != oldHover || hover != nil {
                oldHover = row
                hover = nil
                needsDisplay = true
            }
            return
        }
        oldHover = nil
        let now = cell(at: point)
        if now != hover {
            hover = now
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let crumb = crumbs.first(where: { $0.rect.contains(point) }) {
            if crumb.node != zoom { zoom(to: crumb.node, select: nil) }
            return
        }
        if showOld, oldPanel.contains(point) {
            // A row selects its file: the outline on the map shows where it is.
            if let row = oldRows.first(where: { $0.rect.contains(point) }) {
                message = nil
                selection = row.node
                lastClicked = nil
                selectionChanged()
            }
            return
        }
        guard let tree, let layout, let index = cell(at: point) else { return }
        // Free space is not a file: a click on it only clears the selection.
        guard layout.cells[index].kind != .free else {
            selection = nil
            lastClicked = nil
            return selectionChanged()
        }
        let clicked = layout.cells[index].node
        if event.clickCount >= 2 {
            zoomIn()
            return
        }
        message = nil
        if lastClicked == clicked, let current = selection, tree.isAncestor(current, of: clicked) {
            // The same block again: go up one folder, and from the top back to the block.
            let above = tree.parent[Int(current)]
            selection = above == zoom || above < 0 ? (clicked == zoom ? nil : clicked) : above
        } else {
            selection = clicked == zoom ? nil : clicked
        }
        lastClicked = clicked
        selectionChanged()
    }

    private func selectionChanged() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
        needsDisplay = true
    }

    // MARK: - Zoom

    private func zoom(to node: Int32, select: Int32?) {
        zoom = node
        selection = select
        lastClicked = nil
        message = nil
        relayout()
        loadOldFiles()
        selectionChanged()
    }

    private func zoomIn() {
        guard let tree, let selection else { return }
        let folder = tree.isDirectory(selection) ? selection : tree.parent[Int(selection)]
        guard folder >= 0, folder != zoom, tree.size[Int(folder)] > 0 else { return }
        zoom(to: folder, select: nil)
    }

    private func zoomOut() {
        guard let tree, zoom != 0 else { return }
        zoom(to: tree.parent[Int(zoom)], select: zoom)
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53: window?.performClose(nil)                                   // Escape
        case 13 where command: window?.performClose(nil)                     // Cmd+W
        case 36, 76: zoomIn()                                                // Return
        case 51 where command, 117 where command: trashSelection()           // Cmd+Delete
        case 51, 117: zoomOut()                                              // Delete
        case 49: toggleQuickLook()                                           // Space
        case 15 where command:                                               // Cmd+R
            if let path = selectedPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        case 37:                                                             // L
            guard tree != nil else { return }
            showOld.toggle()
            oldHover = nil
            if showOld { loadOldFiles() } else { needsDisplay = true }
        case 15:                                                             // R
            if !target.isEmpty { start(target) }
        case 8 where command:                                                // Cmd+C
            if let path = selectedPath {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Trash

    private func trashSelection() {
        guard let tree, let node = selection, node != 0, let path = selectedPath else { return NSSound.beep() }
        let size = DiskMapWindow.bytes(Int64(tree.size[Int(node)]))
        let move = { [weak self] in
            guard let self, self.tree === tree else { return }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                // The space is not free until the Trash is emptied, but the item is gone from here.
                self.work.sync { tree.remove(node) }
                self.message = "Moved to the Trash: \((path as NSString).lastPathComponent) (\(size))"
                self.selection = nil
                self.lastClicked = nil
                self.relayout()
                self.loadOldFiles()
            } catch {
                self.message = "Could not move to the Trash: \(error.localizedDescription)"
            }
            self.selectionChanged()
        }
        guard tree.isDirectory(node), let window else { return move() }
        let alert = NSAlert()
        alert.messageText = "Move this folder to the Trash?"
        alert.informativeText = "\((path as NSString).abbreviatingWithTildeInPath)\n\(size)"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { move() } }
    }

    // MARK: - Quick Look

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else if selectedPath != nil {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedPath == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        selectedPath.map { URL(fileURLWithPath: $0) as NSURL }
    }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 49 else { return false }
        panel.orderOut(nil)
        return true
    }
}
