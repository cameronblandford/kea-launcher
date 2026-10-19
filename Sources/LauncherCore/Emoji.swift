import Foundation

/// The emoji list from Resources/emoji.tsv (emoji, name, keywords), searched by word prefix.
public struct EmojiIndex {
    public struct Emoji: Equatable {
        public var char: String
        public var name: String
        public var keywords: [String]
        public init(char: String, name: String, keywords: [String]) {
            self.char = char; self.name = name; self.keywords = keywords
        }
    }

    /// The data has no usage counts, so the everyday ones get a nudge ("heart" → ❤️ first).
    static let popular: Set<String> = ["❤️", "😂", "😭", "✨", "🥺", "🔥", "😊", "👍️", "🙏", "🥰", "💀", "😍", "🎉",
                                       "💕", "🤣", "😅", "🫶", "🙂", "😘", "🤔", "👀", "💯", "😎", "🥲", "😩", "🙃", "⭐️", "🌈", "☀️"]

    public private(set) var all: [Emoji] = []
    private var byChar: [String: Int] = [:]

    public init(tsv: String) {
        for line in tsv.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 2 else { continue }
            let kw = f.count > 2 ? f[2].split(separator: " ").map { $0.lowercased() } : []
            byChar[String(f[0])] = all.count
            all.append(Emoji(char: String(f[0]), name: String(f[1]), keywords: kw))
        }
    }

    public func emoji(for char: String) -> Emoji? { byChar[char].map { all[$0] } }

    /// Every query word must start a word of the name or a keyword. Name hits beat keyword
    /// hits, an exact name wins outright, and frecency (keyed by `idPrefix + emoji`) breaks ties.
    public func search(_ query: String, frecency: Frecency, idPrefix: String = "emoji:", limit: Int = 50) -> [Emoji] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" }).map(String.init)
        if words.isEmpty {
            // Most used first, then the standard order.
            let used = all.filter { frecency.entries[idPrefix + $0.char] != nil }
                .sorted { frecency.multiplier(for: idPrefix + $0.char) > frecency.multiplier(for: idPrefix + $1.char) }
            let rest = all.filter { frecency.entries[idPrefix + $0.char] == nil }
            return Array((used + rest).prefix(limit))
        }
        let strict = rank(words, frecency: frecency, idPrefix: idPrefix, needAll: true)
        // "cozy rainy day" names no single emoji; fall back to emoji matching any of the words.
        let found = strict.isEmpty && words.count > 1 ? rank(words, frecency: frecency, idPrefix: idPrefix, needAll: false) : strict
        return Array(found.prefix(limit))
    }

    private func rank(_ words: [String], frecency: Frecency, idPrefix: String, needAll: Bool) -> [Emoji] {
        var scored: [(Emoji, Double, Int)] = []
        for (order, e) in all.enumerated() {
            let name = e.name.lowercased()
            let nameWords = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == ":" }).map(String.init)
            var score = 0.0
            var ok = true
            for w in words {
                if nameWords.contains(w) { score += 30 }
                else if nameWords.contains(where: { $0.hasPrefix(w) }) { score += 20 }
                else if e.keywords.contains(w) { score += 12 }
                else if e.keywords.contains(where: { $0.hasPrefix(w) }) { score += 8 }
                else if needAll { ok = false; break }
            }
            guard ok, score > 0 else { continue }
            if name == words.joined(separator: " ") { score += 40 }
            // Shorter names are usually the plain form ("heart" over "heart on fire").
            score -= Double(nameWords.count)
            if Self.popular.contains(e.char) { score *= 1.3 }
            score *= frecency.multiplier(for: idPrefix + e.char)
            scored.append((e, score, order))
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
        return scored.map(\.0)
    }
}
