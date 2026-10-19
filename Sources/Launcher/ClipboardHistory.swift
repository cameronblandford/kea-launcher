import AppKit
import LauncherCore

/// Polls the general pasteboard and keeps the last N copies on disk.
/// Text is stored inline; images are written as PNG files next to the index.
final class ClipboardHistory {
    struct Entry: Codable {
        var text: String?
        var image: String?        // file name under the clipboard folder
        var width: Int?
        var height: Int?
        var time: TimeInterval
    }

    private(set) var entries: [Entry] = []
    private let limit: Int
    private var lastChange = NSPasteboard.general.changeCount
    private var suppressNextChange = false
    private var timer: Timer?
    private let indexURL = Paths.root.appendingPathComponent("clipboard.json")
    private let folder = Paths.root.appendingPathComponent("clipboard", isDirectory: true)
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    init(limit: Int) {
        self.limit = limit
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        // A copy we made from history is already at the top; do not record it again.
        if suppressNextChange { suppressNextChange = false; return }
        let types = pb.types ?? []
        // Password managers mark secrets so history tools skip them.
        if types.contains(Self.concealed) || types.contains(Self.transient) { return }

        if let text = pb.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count < 100_000 {
            remove { $0.text == text }
            entries.insert(Entry(text: text, time: Date().timeIntervalSince1970), at: 0)
        } else if let image = imageOnPasteboard(pb), let png = pngData(image) {
            let name = UUID().uuidString + ".png"
            do { try png.write(to: folder.appendingPathComponent(name)) } catch { return }
            let size = pixelSize(image)
            // Same pixels copied twice collapse into one entry.
            remove { $0.image.map { self.fileData($0) == png } ?? false }
            entries.insert(Entry(image: name, width: size.width, height: size.height, time: Date().timeIntervalSince1970), at: 0)
        } else {
            return
        }
        while entries.count > limit { removeEntry(at: entries.count - 1) }
        save()
    }

    private func imageOnPasteboard(_ pb: NSPasteboard) -> NSImage? {
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        guard let types = pb.types, types.contains(where: imageTypes.contains) else { return nil }
        // Files copied in Finder also carry a preview image; only keep real image copies.
        if types.contains(.fileURL) { return nil }
        return NSImage(pasteboard: pb)
    }

    private func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func pixelSize(_ image: NSImage) -> (width: Int, height: Int) {
        if let rep = image.representations.first { return (rep.pixelsWide, rep.pixelsHigh) }
        return (Int(image.size.width), Int(image.size.height))
    }

    private func fileURL(_ name: String) -> URL { folder.appendingPathComponent(name) }
    private func fileData(_ name: String) -> Data? { try? Data(contentsOf: fileURL(name)) }

    private func remove(where match: (Entry) -> Bool) {
        for i in entries.indices.reversed() where match(entries[i]) { removeEntry(at: i) }
    }

    private func removeEntry(at i: Int) {
        if let img = entries[i].image { try? FileManager.default.removeItem(at: fileURL(img)) }
        entries.remove(at: i)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: indexURL, options: .atomic) }
    }

    // MARK: - Mutations from the UI

    /// Puts an entry back on the pasteboard and moves it to the top.
    func reuse(_ entry: Entry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        suppressNextChange = true
        if let img = entry.image, let png = fileData(img) {
            pb.setData(png, forType: .png)
            if let tiff = NSImage(data: png)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        } else if let text = entry.text {
            pb.setString(text, forType: .string)
        }
        lastChange = pb.changeCount
        suppressNextChange = false
        if let i = entries.firstIndex(where: { $0.time == entry.time && $0.text == entry.text && $0.image == entry.image }) {
            var e = entries.remove(at: i)
            e.time = Date().timeIntervalSince1970
            entries.insert(e, at: 0)
            save()
        }
    }

    func delete(_ entry: Entry) {
        remove { $0.time == entry.time && $0.text == entry.text && $0.image == entry.image }
        save()
    }

    func clear() {
        while !entries.isEmpty { removeEntry(at: 0) }
        thumbnails = [:]
        save()
    }

    // MARK: - Results

    func results(filter: String) -> [Result] {
        let textIcon = IconLoader.shared.icon(forSpec: "sf:doc.on.clipboard")
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if f == "clear" {
            let n = entries.count
            return [Result(id: "cb:clear", title: "Clear clipboard history",
                           subtitle: n == 0 ? "History is already empty" : "Removes \(n) \(n == 1 ? "entry" : "entries")",
                           icon: IconLoader.shared.icon(forSpec: "sf:trash"), action: .custom { [weak self] in self?.clear() })]
        }
        let matching = f.isEmpty ? entries : entries.filter { e in
            if let t = e.text { return t.lowercased().contains(f) }
            return "image".contains(f) || f == "img"
        }
        if matching.isEmpty {
            let msg = entries.isEmpty ? "Nothing copied yet" : "No clipboard entries match"
            return [Result(id: "cb:empty", title: msg, subtitle: nil, icon: textIcon, action: .none)]
        }
        return matching.enumerated().map { i, e in
            if let img = e.image {
                let path = fileURL(img).path
                let sub = "\(Self.relative(e.time)) · \(e.width ?? 0)×\(e.height ?? 0) px · Cmd+Y preview · fn+Delete remove"
                return Result(id: "cb:\(i)", title: "Image", subtitle: sub, icon: thumbnail(path),
                              action: .custom { [weak self] in self?.reuse(e) }, revealPath: path,
                              onDelete: { [weak self] in self?.delete(e) })
            }
            let text = e.text ?? ""
            let lines = text.split(whereSeparator: \.isNewline)
            let first = lines.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? text
            let title = first.count > 90 ? String(first.prefix(90)) + "…" : first
            var sub = Self.relative(e.time)
            if lines.count > 1 { sub += " · \(lines.count) lines" }
            sub += " · \(text.count) chars"
            return Result(id: "cb:\(i)", title: title, subtitle: sub, icon: textIcon,
                          action: .custom { [weak self] in self?.reuse(e) },
                          onDelete: { [weak self] in self?.delete(e) })
        }
    }

    private var thumbnails: [String: NSImage] = [:]

    private func thumbnail(_ path: String) -> NSImage? {
        if let t = thumbnails[path] { return t }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        let side: CGFloat = 32
        let scale = min(side / max(img.size.width, 1), side / max(img.size.height, 1))
        let size = NSSize(width: img.size.width * scale, height: img.size.height * scale)
        let thumb = NSImage(size: NSSize(width: side, height: side))
        thumb.lockFocus()
        img.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        thumb.unlockFocus()
        thumbnails[path] = thumb
        return thumb
    }


    private static func relative(_ t: TimeInterval) -> String {
        let age = Date().timeIntervalSince1970 - t
        if age < 60 { return "just now" }
        if age < 3600 { return "\(Int(age / 60)) min ago" }
        if age < 86400 { return "\(Int(age / 3600)) h ago" }
        return "\(Int(age / 86400)) d ago"
    }
}

extension ClipboardHistory {
    func command(keyword: String) -> KeaCommand {
        KeaCommand(id: "clipboard", name: "Clipboard History", keywords: [keyword],
                   help: [.init(keyword: keyword, summary: "Clipboard history, text and images", example: "cb · cb image · cb clear")],
                   results: { [unowned self] in Array(results(filter: $0.argument).prefix(50)) })
    }
}
