import AppKit
import LauncherCore

/// Puts text on the clipboard and, with Accessibility access, pastes it into the app
/// that was in front before the panel opened.
enum Paste {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Without Accessibility, Return can only copy; rows say so instead of failing silently.
    private static var checked: (at: Date, ok: Bool)?
    /// Checked at most every two seconds; rows ask once each.
    static var canPaste: Bool {
        if let c = checked, Date().timeIntervalSince(c.at) < 2 { return c.ok }
        let ok = AXIsProcessTrusted()
        checked = (Date(), ok)
        return ok
    }
    static var hint: String { canPaste ? "Return pastes" : "Return copies · paste needs Accessibility (Settings › Privacy)" }

    static func paste(_ text: String) {
        copy(text)
        guard AXIsProcessTrusted() else { Log.write("paste: no Accessibility access, copied only"); return }
        // The panel hides first and hands focus back; give the app a moment to take it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)   // V
            let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }
}

/// Emoji drawn as an image, for the row icon.
enum EmojiImage {
    private static var cache: [String: NSImage] = [:]
    static func image(_ s: String, size: CGFloat = 30) -> NSImage {
        let key = "\(s)|\(size)"
        if let hit = cache[key] { return hit }
        let font = NSFont.systemFont(ofSize: size * 0.82)
        let attr = NSAttributedString(string: s, attributes: [.font: font])
        let bounds = attr.size()
        let width = max(size, ceil(bounds.width))
        let img = NSImage(size: NSSize(width: width, height: size), flipped: false) { rect in
            attr.draw(at: NSPoint(x: (rect.width - bounds.width) / 2, y: (rect.height - bounds.height) / 2))
            return true
        }
        cache[key] = img
        return img
    }
}

/// Adds rows to the emoji list for a query. Kea's own build has one, which suggests emoji
/// sequences; the public build has none.
protocol EmojiAssistant: AnyObject {
    /// The `help` line of `e` while this is in use.
    var help: HelpProvider.Entry { get }
    /// Rows for the query, to go under the top three of the search. `refresh` draws the
    /// list again when an answer arrives.
    func rows(for query: String, refresh: @escaping () -> Void) -> [Result]
}

/// `e party`, `emoji cozy rainy day`: local search by name and keyword, most used first.
/// Return pastes.
final class EmojiCommand {
    static let keywords: Set<String> = ["e", "emoji"]
    private let index: EmojiIndex
    private let assistant: EmojiAssistant?

    init(assistant: EmojiAssistant?) {
        self.assistant = assistant
        index = EmojiIndex(tsv: Self.loadTSV())
    }

    private static func loadTSV() -> String {
        var urls: [URL] = []
        if let u = Bundle.main.url(forResource: "emoji", withExtension: "tsv") { urls.append(u) }
        // `--query` runs from .build/release, without a bundle.
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<4 {
            dir = dir.deletingLastPathComponent()
            urls.append(dir.appendingPathComponent("Resources/emoji.tsv"))
        }
        for u in urls { if let s = try? String(contentsOf: u, encoding: .utf8) { return s } }
        Log.write("emoji: emoji.tsv not found")
        return ""
    }

    func results(argument: String, frecency: Frecency, refresh: @escaping () -> Void) -> [Result] {
        let q = argument.trimmingCharacters(in: .whitespaces)
        let local = index.search(q, frecency: frecency, limit: q.isEmpty ? 40 : 24)
        var rows = local.map { row($0.char, name: $0.name, detail: $0.keywords.prefix(6).joined(separator: " ")) }
        // The search finds single emoji well; an assistant's rows go under its top three.
        rows.insert(contentsOf: assistant?.rows(for: q, refresh: refresh) ?? [], at: min(3, rows.count))
        return rows
    }

    private func row(_ char: String, name: String, detail: String, id: String? = nil) -> Result {
        Result(id: id ?? "emoji:\(char)", title: name.prefix(1).uppercased() + name.dropFirst(),
               subtitle: Paste.canPaste ? (detail.isEmpty ? nil : detail) : Paste.hint,
               icon: EmojiImage.image(char), action: .custom { Paste.paste(char) }, keyword: detail)
    }
}

/// `zalgo hello`: three strengths of Z̴̡a̸l̷g̶o̵ text. Return copies.
enum ZalgoCommand {
    static let keywords: Set<String> = ["zalgo"]

    static func results(argument: String) -> [Result] {
        let text = argument.trimmingCharacters(in: .whitespaces)
        let icon = IconLoader.shared.icon(forSpec: "sf:scribble.variable")
        guard !text.isEmpty else {
            return [Result(id: "zalgo:help", title: Zalgo.generate("Zalgo text", level: .mild), subtitle: "zalgo hello · Return copies",
                           icon: icon, action: .none)]
        }
        // Seeded by the text, so the row shown is exactly what gets copied.
        let seed = text.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
        return Zalgo.Level.allCases.reversed().map { level in
            let s = Zalgo.generate(text, level: level, seed: seed)
            return Result(id: "zalgo:\(level.rawValue)", title: s, subtitle: "\(level.title) · Return copies", icon: icon, action: .item(.copy(s)))
        }
    }
}

extension EmojiCommand {
    var command: KeaCommand {
        KeaCommand(id: "emoji", name: "Emoji", keywords: Self.keywords,
                   help: [assistant?.help ?? .init(keyword: "e", summary: "Emoji by name, most used first. Return pastes", example: "e party")],
                   results: { [unowned self] in results(argument: $0.argument, frecency: $0.frecency, refresh: $0.refresh) })
    }
}

extension ZalgoCommand {
    static var command: KeaCommand {
        KeaCommand(id: "zalgo", name: "Zalgo Text", keywords: keywords,
                   help: [.init(keyword: "zalgo", summary: "Z̴a̷l̶g̸o̵ text in three strengths. Return copies", example: "zalgo hello")],
                   results: { results(argument: $0.argument) })
    }
}
