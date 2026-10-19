import Foundation

public struct Rankable {
    public var id: String
    public var text: String
    /// Extra text that can match with a lower weight, like a keyword or path.
    public var secondary: String?

    public init(id: String, text: String, secondary: String? = nil) {
        self.id = id
        self.text = text
        self.secondary = secondary
    }
}

public struct Ranked {
    public var id: String
    public var score: Double

    public init(id: String, score: Double) {
        self.id = id
        self.score = score
    }
}

public enum Ranker {
    public static func rank(_ items: [Rankable], query: String, frecency: Frecency, now: TimeInterval = Date().timeIntervalSince1970) -> [Ranked] {
        var out: [Ranked] = []
        out.reserveCapacity(items.count)
        for item in items {
            var best = FuzzyMatcher.score(query: query, candidate: item.text)
            if let s = item.secondary, let alt = FuzzyMatcher.score(query: query, candidate: s) {
                let weighted = alt * 0.6
                best = max(best ?? -Double.infinity, weighted)
            }
            guard let base = best else { continue }
            let m = frecency.multiplier(for: item.id, now: now)
            // Keep a positive baseline so the multiplier always helps.
            out.append(Ranked(id: item.id, score: (base + 100) * m))
        }
        return out.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.id < b.id
        }
    }
}
