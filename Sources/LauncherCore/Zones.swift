import CoreGraphics
import Foundation

/// A per-display zone layout, parsed from strings like `cols 2`, `rows 3`,
/// `cols(zone, rows 2)` or `cols(2*zone, zone)`. Weights default to 1.
public indirect enum ZoneLayout: Equatable {
    case zone
    case split(vertical: Bool, [(weight: Double, node: ZoneLayout)])

    public static func == (a: ZoneLayout, b: ZoneLayout) -> Bool {
        switch (a, b) {
        case (.zone, .zone): return true
        case let (.split(v1, c1), .split(v2, c2)):
            return v1 == v2 && c1.count == c2.count && zip(c1, c2).allSatisfy { $0.weight == $1.weight && $0.node == $1.node }
        default: return false
        }
    }

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func parse(_ text: String) throws -> ZoneLayout {
        var p = Parser(tokens: tokenize(text.lowercased()))
        let (_, node) = try p.node()
        guard p.atEnd else { throw ParseError(description: "unexpected \"\(p.peek ?? "")\" in layout: \(text)") }
        return node
    }

    /// Zone rectangles inside `area`, in reading order. `area` uses a top-left origin.
    public func rects(in area: CGRect) -> [CGRect] {
        switch self {
        case .zone:
            return [area]
        case let .split(vertical, children):
            let total = children.reduce(0) { $0 + $1.weight }
            var offset: CGFloat = 0
            var out: [CGRect] = []
            for child in children {
                let share = CGFloat(child.weight / total)
                let r: CGRect
                if vertical {
                    r = CGRect(x: area.minX, y: area.minY + offset * area.height, width: area.width, height: share * area.height)
                } else {
                    r = CGRect(x: area.minX + offset * area.width, y: area.minY, width: share * area.width, height: area.height)
                }
                offset += share
                out += child.node.rects(in: r)
            }
            return out
        }
    }

    private static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "." {
                word.append(ch)
            } else {
                if !word.isEmpty { tokens.append(word); word = "" }
                if "(),*".contains(ch) { tokens.append(String(ch)) }
            }
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens
    }

    private struct Parser {
        let tokens: [String]
        var i = 0
        var atEnd: Bool { i >= tokens.count }
        var peek: String? { atEnd ? nil : tokens[i] }

        mutating func next() throws -> String {
            guard let t = peek else { throw ParseError(description: "layout ended early") }
            i += 1
            return t
        }

        mutating func expect(_ t: String) throws {
            let got = try next()
            guard got == t else { throw ParseError(description: "expected \"\(t)\", got \"\(got)\"") }
        }

        mutating func node() throws -> (Double, ZoneLayout) {
            var weight = 1.0
            if let t = peek, let w = Double(t), i + 1 < tokens.count, tokens[i + 1] == "*" {
                guard w > 0 else { throw ParseError(description: "weight must be positive") }
                weight = w
                i += 2
            }
            let word = try next()
            switch word {
            case "zone", "z", "full":
                return (weight, .zone)
            case "rows", "cols", "columns":
                let vertical = word == "rows"
                if peek == "(" {
                    i += 1
                    var children = [try node()]
                    while peek == "," { i += 1; children.append(try node()) }
                    try expect(")")
                    return (weight, .split(vertical: vertical, children.map { (weight: $0.0, node: $0.1) }))
                }
                guard let n = Int(try next()), n >= 1, n <= 12 else {
                    throw ParseError(description: "\(word) needs a count from 1 to 12 or a list in parentheses")
                }
                return (weight, .split(vertical: vertical, Array(repeating: (weight: 1.0, node: ZoneLayout.zone), count: n)))
            default:
                throw ParseError(description: "unknown word \"\(word)\" in layout")
            }
        }
    }
}

public enum ZoneDirection: String, CaseIterable {
    case left, right, up, down
}

public enum ZoneNavigator {
    /// All zones across displays in loop order: displays left to right (then top to
    /// bottom), zones in each display's reading order. Frames use a top-left origin.
    public static func globalZones(displays: [(frame: CGRect, layout: ZoneLayout)], gap: CGFloat) -> [CGRect] {
        let sorted = displays.sorted { a, b in
            a.frame.minX != b.frame.minX ? a.frame.minX < b.frame.minX : a.frame.minY < b.frame.minY
        }
        let half = max(0, gap) / 2
        return sorted.flatMap { d in
            d.layout.rects(in: d.frame.insetBy(dx: half, dy: half)).map { $0.insetBy(dx: half, dy: half).integral }
        }
    }

    /// The zone a window is in. `snapped` is false when the window only overlaps it.
    public static func locate(_ frame: CGRect, in zones: [CGRect]) -> (index: Int, snapped: Bool)? {
        guard !zones.isEmpty else { return nil }
        func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
        var best = -1
        var bestScore: CGFloat = -1
        for (i, z) in zones.enumerated() {
            let inter = area(z.intersection(frame))
            let union = area(z) + area(frame) - inter
            let score = union > 0 ? inter / union : 0
            if score > bestScore { bestScore = score; best = i }
        }
        if bestScore <= 0 {
            // Off every zone: take the nearest centre.
            let c = CGPoint(x: frame.midX, y: frame.midY)
            best = zones.indices.min { dist(zones[$0], c) < dist(zones[$1], c) }!
            return (best, false)
        }
        return (best, bestScore >= 0.85)
    }

    /// Left and right step through the loop order and wrap. Up and down go to the
    /// nearest zone above or below that shares some width, wrapping within that column.
    public static func target(from index: Int, _ direction: ZoneDirection, zones: [CGRect]) -> Int? {
        guard zones.indices.contains(index) else { return nil }
        let n = zones.count
        switch direction {
        case .right: return (index + 1) % n
        case .left: return (index - 1 + n) % n
        case .up, .down:
            let cur = zones[index]
            let column = zones.indices.filter { $0 != index && overlapsHorizontally(zones[$0], cur) }
            guard !column.isEmpty else { return nil }
            let up = direction == .up
            let ahead = column.filter { up ? zones[$0].midY < cur.midY : zones[$0].midY > cur.midY }
            if !ahead.isEmpty {
                return ahead.min { abs(zones[$0].midY - cur.midY) < abs(zones[$1].midY - cur.midY) }
            }
            // Wrap to the far end of the column.
            return column.max { up ? zones[$0].midY < zones[$1].midY : zones[$0].midY > zones[$1].midY }
        }
    }

    /// Where a window that is not in a zone starts, on the display it mostly covers:
    /// Left picks the first zone (reading order) on the display's left edge, Right the
    /// first on its right edge. `displays` are the displays' usable areas.
    public static func entry(for frame: CGRect, _ direction: ZoneDirection = .left, displays: [CGRect], zones: [CGRect]) -> Int? {
        func overlap(_ r: CGRect) -> CGFloat { let i = r.intersection(frame); return i.isNull ? 0 : i.width * i.height }
        let c = CGPoint(x: frame.midX, y: frame.midY)
        guard let display = displays.max(by: { a, b in
            overlap(a) != overlap(b) ? overlap(a) < overlap(b) : dist(a, c) > dist(b, c)
        }) else { return zones.isEmpty ? nil : 0 }
        let mine = zones.indices.filter { display.contains(CGPoint(x: zones[$0].midX, y: zones[$0].midY)) }
        guard !mine.isEmpty else { return zones.isEmpty ? nil : 0 }
        if direction == .right {
            let edge = mine.map { zones[$0].maxX }.max()!
            return mine.first { zones[$0].maxX >= edge - 2 }
        }
        let edge = mine.map { zones[$0].minX }.min()!
        return mine.first { zones[$0].minX <= edge + 2 }
    }

    private static func overlapsHorizontally(_ a: CGRect, _ b: CGRect) -> Bool {
        min(a.maxX, b.maxX) - max(a.minX, b.minX) > min(a.width, b.width) * 0.25
    }

    private static func dist(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        hypot(r.midX - p.x, r.midY - p.y)
    }
}

/// The rules of the drop zones: with Shift held while a window is dragged, the zones
/// show, and the window goes into the one under the pointer.
public enum ZoneDrop {
    /// The zones a drop at `point` fills. Only zones on the display under the pointer
    /// count. Near the border of two or more zones (within `margin`), all of them count,
    /// and the window spans them. A point outside every zone (in the gap at a display's
    /// edge) takes the nearest zone, so there is always a target on that display.
    public static func targets(at point: CGPoint, zones: [CGRect], displays: [CGRect], margin: CGFloat = 28) -> [Int] {
        guard let display = displays.first(where: { $0.contains(point) }) else { return [] }
        let local = zones.indices.filter { display.contains(CGPoint(x: zones[$0].midX, y: zones[$0].midY)) }
        let near = local.filter { zones[$0].insetBy(dx: -margin, dy: -margin).contains(point) }
        if !near.isEmpty {
            // Inside one zone and far from its edges, `near` is that zone alone.
            return near
        }
        func distance(_ r: CGRect) -> CGFloat {
            let dx = max(r.minX - point.x, 0, point.x - r.maxX), dy = max(r.minY - point.y, 0, point.y - r.maxY)
            return (dx * dx + dy * dy).squareRoot()
        }
        return local.min { distance(zones[$0]) < distance(zones[$1]) }.map { [$0] } ?? []
    }

    /// The frame for a window dropped on these zones: the rectangle around all of them.
    public static func frame(of indexes: [Int], zones: [CGRect]) -> CGRect? {
        guard let first = indexes.first, zones.indices.contains(first) else { return nil }
        return indexes.dropFirst().reduce(zones[first]) { zones.indices.contains($1) ? $0.union(zones[$1]) : $0 }
    }

    /// True when a window moved the way the pointer did between two looks at it: it is
    /// being dragged by its title bar. A window that stays put (the drag is a text
    /// selection or a file) or changes size (the drag is a resize) is not.
    public static func isWindowDrag(windowBefore: CGRect, windowAfter: CGRect, pointerBefore: CGPoint, pointerAfter: CGPoint, tolerance: CGFloat = 8) -> Bool {
        guard abs(windowAfter.width - windowBefore.width) < 2, abs(windowAfter.height - windowBefore.height) < 2 else { return false }
        let wx = windowAfter.minX - windowBefore.minX, wy = windowAfter.minY - windowBefore.minY
        let px = pointerAfter.x - pointerBefore.x, py = pointerAfter.y - pointerBefore.y
        guard abs(wx) + abs(wy) >= 4 else { return false }
        return abs(wx - px) <= tolerance && abs(wy - py) <= tolerance
    }
}
