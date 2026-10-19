import Foundation

/// Zalgo text: combining marks stacked above, through, and below each letter.
public enum Zalgo {
    public enum Level: String, CaseIterable {
        case mild, medium, max
        public var title: String { rawValue.capitalized }
        var counts: (up: ClosedRange<Int>, mid: ClosedRange<Int>, down: ClosedRange<Int>) {
            switch self {
            case .mild: return (1...3, 0...1, 1...3)
            case .medium: return (3...8, 0...2, 3...8)
            case .max: return (8...18, 1...4, 8...18)
            }
        }
    }

    static let up: [UInt32] = [0x030D, 0x030E, 0x0304, 0x0305, 0x033F, 0x0311, 0x0306, 0x0310, 0x0352, 0x0357,
                               0x0351, 0x0307, 0x0308, 0x030A, 0x0342, 0x0343, 0x0344, 0x034A, 0x034B, 0x034C,
                               0x0303, 0x0302, 0x030C, 0x0350, 0x0300, 0x0301, 0x030B, 0x030F, 0x0312, 0x0313,
                               0x0314, 0x033D, 0x0309, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
                               0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x033E, 0x035B, 0x0346, 0x031A]
    static let mid: [UInt32] = [0x0315, 0x031B, 0x0340, 0x0341, 0x0358, 0x0321, 0x0322, 0x0327, 0x0328, 0x0334,
                                0x0335, 0x0336, 0x034F, 0x035C, 0x035D, 0x035E, 0x035F, 0x0360, 0x0362, 0x0338,
                                0x0337, 0x0361, 0x0489]
    static let down: [UInt32] = [0x0316, 0x0317, 0x0318, 0x0319, 0x031C, 0x031D, 0x031E, 0x031F, 0x0320, 0x0324,
                                 0x0325, 0x0326, 0x0329, 0x032A, 0x032B, 0x032C, 0x032D, 0x032E, 0x032F, 0x0330,
                                 0x0331, 0x0332, 0x0333, 0x0339, 0x033A, 0x033B, 0x033C, 0x0345, 0x0347, 0x0348,
                                 0x0349, 0x034D, 0x034E, 0x0353, 0x0354, 0x0355, 0x0356, 0x0359, 0x035A, 0x0323]

    /// The same text, level and seed always give the same result, so the preview row is what gets copied.
    public static func generate(_ text: String, level: Level, seed: UInt64 = 1) -> String {
        var rng = SplitMix(seed: seed)
        var out = String.UnicodeScalarView()
        let c = level.counts
        for ch in text {
            out.append(contentsOf: ch.unicodeScalars)
            guard !ch.isWhitespace else { continue }
            for (pool, range) in [(up, c.up), (mid, c.mid), (down, c.down)] {
                for _ in 0..<rng.int(in: range) {
                    if let s = Unicode.Scalar(pool[rng.int(in: 0...(pool.count - 1))]) { out.append(s) }
                }
            }
        }
        return String(out)
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}
