import AppKit
import CoreServices

/// Looks words up in the system dictionary via DictionaryServices.
enum DictionaryLookup {
    static func definition(of word: String) -> String? {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let range = CFRangeMake(0, (trimmed as NSString).length)
        guard let def = DCSCopyTextDefinition(nil, trimmed as CFString, range)?.takeRetainedValue() else { return nil }
        return String(def)
    }

    static func result(for word: String) -> Result {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        let icon = IconLoader.shared.icon(forSpec: "sf:character.book.closed")
        guard !trimmed.isEmpty else {
            return Result(id: "define:", title: "Define a word", subtitle: "Type a word to look it up", icon: icon, action: .none)
        }
        let dictURL = "dict://\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed)"
        guard let def = definition(of: trimmed) else {
            return Result(id: "define:\(trimmed)", title: trimmed, subtitle: "No definition found. Return opens Dictionary.",
                          icon: icon, action: .item(.open(dictURL)))
        }
        return Result(id: "define:\(trimmed)", title: trimmed, subtitle: summary(of: def, headword: trimmed),
                      icon: icon, action: .item(.open(dictURL)), expanded: true)
    }

    // MARK: - Etymology

    static let etymologyKeywords: Set<String> = ["ety", "etym", "etymology", "origin"]

    /// The ORIGIN section of the system dictionary entry, if the entry has one.
    static func origin(of word: String) -> String? {
        guard let def = definition(of: word) else { return nil }
        let text = def.replacingOccurrences(of: "\n", with: " ")
        guard let r = text.range(of: " ORIGIN ") ?? text.range(of: "ORIGIN ") else { return nil }
        var origin = String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        // Entries with several senses may restart with usage notes after the origin.
        for marker in [" USAGE ", " DERIVATIVES ", " PHRASES "] {
            if let m = origin.range(of: marker) { origin = String(origin[..<m.lowerBound]) }
        }
        return origin.isEmpty ? nil : origin
    }

    static func etymologyResults(for word: String) -> [Result] {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        let icon = IconLoader.shared.icon(forSpec: "sf:book.closed")
        guard !trimmed.isEmpty else {
            return [Result(id: "ety:", title: "Etymology", subtitle: "Type a word to see where it comes from", icon: icon, action: .none)]
        }
        let dictURL = "dict://\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed)"
        let web = "https://www.etymonline.com/search?q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed)"
        var out: [Result] = []
        if let o = origin(of: trimmed) {
            out.append(Result(id: "ety:\(trimmed)", title: trimmed, subtitle: o, icon: icon, action: .item(.open(dictURL)), expanded: true))
        } else {
            out.append(Result(id: "ety:\(trimmed)", title: trimmed, subtitle: "No origin in the system dictionary. Return opens Dictionary.",
                              icon: icon, action: .item(.open(dictURL))))
        }
        out.append(Result(id: "ety:web:\(trimmed)", title: "Search etymonline.com", subtitle: "Full history of \"\(trimmed)\"",
                          icon: IconLoader.shared.icon(forSpec: "sf:globe"), action: .item(.open(web))))
        return out
    }

    /// Drop the repeated headword and syllabification, keep the pronunciation and the senses
    /// up to the phrases/origin sections, and cut at a word boundary.
    static func summary(of definition: String, headword: String, limit: Int = 700) -> String {
        var text = definition.replacingOccurrences(of: "\n", with: " ")
        if text.lowercased().hasPrefix(headword.lowercased()) { text = String(text.dropFirst(headword.count)) }
        // Syllabified form like "ser·en·dip·i·ty" follows the headword.
        if let bar = text.firstIndex(of: "|"), text[..<bar].contains("·") { text = String(text[bar...]) }
        text = text.trimmingCharacters(in: .whitespaces)
        for marker in [" PHRASES ", " ORIGIN ", " DERIVATIVES ", " USAGE "] {
            if let r = text.range(of: marker) { text = String(text[..<r.lowerBound]) }
        }
        guard text.count > limit else { return text }
        let cut = text.index(text.startIndex, offsetBy: limit)
        let head = text[..<cut]
        let atWord = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return atWord + "…"
    }
}

extension DictionaryLookup {
    static func defineCommand(keywords: [String]) -> KeaCommand {
        KeaCommand(id: "define", name: "Dictionary", keywords: Set(keywords),
                   help: [.init(keyword: keywords.first ?? "def", summary: "Dictionary definition", example: "def serendipity")],
                   results: { [result(for: $0.argument)] })
    }

    static var etymologyCommand: KeaCommand {
        KeaCommand(id: "etymology", name: "Etymology", keywords: etymologyKeywords,
                   help: [.init(keyword: "ety", summary: "Word origin", example: "ety apple")],
                   results: { etymologyResults(for: $0.argument) })
    }
}
