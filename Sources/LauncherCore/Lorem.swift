import Foundation

/// Placeholder text. The first sentence is always the classic opening so it reads as lorem ipsum at a glance.
public enum Lorem {
    public enum Kind: String, CaseIterable {
        case phrase, sentence, paragraph, fiveParagraphs

        public var title: String {
            switch self {
            case .phrase: return "Phrase"
            case .sentence: return "Sentence"
            case .paragraph: return "Paragraph"
            case .fiveParagraphs: return "5 Paragraphs"
            }
        }
    }

    static let opening = "Lorem ipsum dolor sit amet, consectetur adipiscing elit"

    static let words = """
    a ac accumsan ad adipiscing aenean aliquam aliquet amet ante aptent arcu at auctor augue bibendum blandit \
    class commodo condimentum congue consectetur consequat conubia convallis cras cubilia curabitur curae cursus \
    dapibus diam dictum dictumst dignissim dis dolor donec dui duis efficitur egestas eget eleifend elementum elit \
    enim erat eros est et etiam eu euismod ex facilisi facilisis fames faucibus felis fermentum feugiat finibus \
    fringilla fusce gravida habitant habitasse hac hendrerit himenaeos iaculis id imperdiet in inceptos integer \
    interdum ipsum justo lacinia lacus laoreet lectus leo libero ligula litora lobortis lorem luctus maecenas \
    magna magnis malesuada massa mattis mauris maximus metus mi molestie mollis montes morbi mus nam nascetur \
    natoque nec neque netus nibh nisi nisl non nostra nulla nullam nunc odio orci ornare parturient pellentesque \
    penatibus per pharetra phasellus placerat platea porta porttitor posuere potenti praesent pretium primis \
    proin pulvinar purus quam quis quisque rhoncus ridiculus risus rutrum sagittis sapien scelerisque sed sem \
    semper senectus sit sociosqu sodales sollicitudin suscipit suspendisse taciti tellus tempor tempus tincidunt \
    torquent tortor tristique turpis ullamcorper ultrices ultricies urna ut varius vehicula vel velit venenatis \
    vestibulum vitae vivamus viverra volutpat vulputate
    """.split(separator: " ").map(String.init)

    public static func generate(_ kind: Kind, seed: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) -> String {
        var rng = SplitMix(seed: seed)
        switch kind {
        case .phrase:
            return phrase(&rng)
        case .sentence:
            return opening + "."
        case .paragraph:
            return paragraph(&rng, first: true)
        case .fiveParagraphs:
            return (0..<5).map { paragraph(&rng, first: $0 == 0) }.joined(separator: "\n\n")
        }
    }

    /// Sentence case, no period: reads as a title.
    static func phrase(_ rng: inout SplitMix) -> String {
        let n = Int(rng.next() % 3) + 4
        let text = (0..<n).map { _ in words[Int(rng.next() % UInt64(words.count))] }.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func sentence(_ rng: inout SplitMix) -> String {
        let n = Int(rng.next() % 9) + 6
        var parts = (0..<n).map { _ in words[Int(rng.next() % UInt64(words.count))] }
        if n > 9 { parts[n / 2] += "," }
        return parts.joined(separator: " ").prefix(1).uppercased() + parts.joined(separator: " ").dropFirst() + "."
    }

    static func paragraph(_ rng: inout SplitMix, first: Bool) -> String {
        let n = Int(rng.next() % 3) + 4
        var sentences = (0..<n).map { _ in sentence(&rng) }
        if first { sentences[0] = opening + "." }
        return sentences.joined(separator: " ")
    }

    // MARK: N paragraphs, plain or Markdown

    public struct Request: Equatable {
        public var paragraphs: Int
        public var markdown: Bool
    }

    /// `3`, `3 md`, `md 3`, `md`, `markdown 12`. A number is how many paragraphs (1 to 100);
    /// `md` alone means 5. Nil when the text is neither.
    public static func parseRequest(_ text: String) -> Request? {
        var count: Int?
        var markdown = false
        let words = text.lowercased().split(separator: " ")
        guard !words.isEmpty else { return nil }
        for w in words {
            if ["md", "markdown"].contains(w) { markdown = true }
            else if let n = Int(w), count == nil { count = n }
            else { return nil }
        }
        guard markdown || count != nil else { return nil }
        return Request(paragraphs: min(max(count ?? 5, 1), 100), markdown: markdown)
    }

    public static func paragraphs(_ n: Int, seed: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) -> String {
        var rng = SplitMix(seed: seed)
        return (0..<max(1, n)).map { paragraph(&rng, first: $0 == 0) }.joined(separator: "\n\n")
    }

    /// `n` paragraphs as a Markdown document that exercises a renderer: a title,
    /// section headers, bold, italic and a link inside paragraphs, and between them an
    /// image, a bullet list, a quote, a numbered list, a code block and a table in turn.
    public static func markdown(paragraphs n: Int, seed: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) -> String {
        var rng = SplitMix(seed: seed)
        func word() -> String { words[Int(rng.next() % UInt64(words.count))] }
        func items(_ count: Int) -> [String] { (0..<count).map { _ in phrase(&rng) } }
        var blocks = ["# " + phrase(&rng)]
        for i in 0..<max(1, n) {
            if i > 0, i % 2 == 0 { blocks.append((i % 4 == 0 ? "## " : "### ") + phrase(&rng)) }
            var p = paragraph(&rng, first: i == 0)
            // Inline styles in every other paragraph, on words after the opening sentence.
            if i % 2 == 1 || n == 1 {
                var parts = p.split(separator: " ").map(String.init)
                if parts.count > 16 {
                    parts[10] = "**" + parts[10].trimmingCharacters(in: .punctuationCharacters) + "**"
                    parts[13] = "*" + parts[13].trimmingCharacters(in: .punctuationCharacters) + "*"
                    parts[16] = "[" + parts[16].trimmingCharacters(in: .punctuationCharacters) + "](https://example.com)"
                    p = parts.joined(separator: " ")
                }
            }
            blocks.append(p)
            switch i % 6 {
            case 0:
                // picsum.photos serves a stable placeholder photo for a seed word.
                let alt = phrase(&rng)
                blocks.append("![\(alt)](https://picsum.photos/seed/\(word())/1200/600)\n*\(phrase(&rng))*")
            case 1:
                blocks.append(items(3).map { "- " + $0 }.joined(separator: "\n"))
            case 2:
                blocks.append("> " + sentence(&rng))
            case 3:
                blocks.append(items(3).enumerated().map { "\($0.offset + 1). " + $0.element }.joined(separator: "\n"))
            case 4:
                blocks.append("```js\nconst \(word()) = \"\(word())\";\nconsole.log(\(word()));\n```")
            default:
                let rows = (0..<3).map { _ in "| \(word()) | \(word()) | \(Int(rng.next() % 90) + 10) |" }
                blocks.append((["| \(word().capitalized) | \(word().capitalized) | \(word().capitalized) |", "|---|---|---|"] + rows).joined(separator: "\n"))
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Tiny deterministic generator so tests can pin output.
    public struct SplitMix {
        var state: UInt64
        public init(seed: UInt64) { state = seed }
        public mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}
