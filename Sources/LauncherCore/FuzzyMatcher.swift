import Foundation

/// Subsequence matcher with bonuses for prefix, word-start, and adjacency.
/// Returns nil when the query is not a subsequence of the candidate.
public enum FuzzyMatcher {
    /// Index of a word in `c` that begins with `q`, or nil.
    private static func wordPrefixIndex(_ q: [Character], in c: [Character]) -> Int? {
        var i = 1
        while i + q.count <= c.count {
            let boundary = !c[i - 1].isLetter && !c[i - 1].isNumber
            if boundary, Array(c[i..<i + q.count]) == q { return i }
            i += 1
        }
        return nil
    }

    public static func score(query: String, candidate: String) -> Double? {
        let q = Array(query.lowercased())
        if q.isEmpty { return 0 }
        let c = Array(candidate.lowercased())
        if c.isEmpty { return nil }

        if q == c { return 1000 }
        if c.starts(with: q) { return 500 + Double(q.count) * 10 - Double(c.count) * 0.1 }
        // "chr" should find "Google Chrome" nearly as well as it finds "Chrome".
        if let wordStart = wordPrefixIndex(q, in: c) {
            return 450 + Double(q.count) * 10 - Double(c.count) * 0.1 - Double(wordStart) * 0.5
        }

        var score = 0.0
        var qi = 0
        var lastMatch = -2
        for (ci, ch) in c.enumerated() {
            guard qi < q.count, ch == q[qi] else { continue }
            var gain = 10.0
            let atWordStart = ci == 0 || !c[ci - 1].isLetter && !c[ci - 1].isNumber
            if atWordStart { gain += 20 }
            if ci == lastMatch + 1 { gain += 8 }
            if ci == 0 { gain += 10 }
            score += gain
            lastMatch = ci
            qi += 1
        }
        guard qi == q.count else { return nil }
        // Prefer shorter candidates and matches that sit early in the string.
        score -= Double(c.count) * 0.2
        score -= Double(lastMatch) * 0.5
        return score
    }
}
