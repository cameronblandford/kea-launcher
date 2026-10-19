import Foundation

/// One mark on an image in the `ie` editor. Points are in image space, 0...1 on each axis
/// with the origin at the top left, so marks keep their place at any display size.
public struct Markup: Codable, Equatable {
    public enum Kind: String, Codable, CaseIterable { case pen, box, arrow, text, redact, highlight, mosaic }

    public var kind: Kind
    public var points: [Point]
    public var color: PastelColor
    public var text: String

    public struct Point: Codable, Equatable {
        public var x: Double
        public var y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    public init(kind: Kind, points: [Point], color: PastelColor = .pink, text: String = "") {
        self.kind = kind; self.points = points; self.color = color; self.text = text
    }

    /// The mark shifted by `dx`, `dy` (in 0...1 image units). The shift is cut short so
    /// every point stays inside the image.
    public func moved(dx: Double, dy: Double) -> Markup {
        guard !points.isEmpty else { return self }
        let xs = points.map(\.x), ys = points.map(\.y)
        let cx = min(max(dx, -xs.min()!), 1 - xs.max()!)
        let cy = min(max(dy, -ys.min()!), 1 - ys.max()!)
        var m = self
        m.points = points.map { Point($0.x + cx, $0.y + cy) }
        return m
    }

    /// Whether a click at `p` (0...1 image units) is on this mark, for moving it.
    /// `width` and `height` are the image's size as drawn, so `tolerance` is in drawn
    /// points. Filled marks (highlight, redact, mosaic) take anywhere inside; a box takes
    /// only its outline, so drawing inside a box still works; arrows and pen strokes
    /// take a band around the line. `textSize` is the label's drawn size, for text marks.
    public func hit(_ p: Point, width: Double, height: Double, tolerance: Double, textSize: (w: Double, h: Double)? = nil) -> Bool {
        guard !points.isEmpty else { return false }
        func d(_ q: Point) -> (x: Double, y: Double) { (q.x * width, q.y * height) }
        let c = d(p)
        func rect() -> (x0: Double, y0: Double, x1: Double, y1: Double) {
            let a = d(points[0]), b = d(points[points.count - 1])
            return (min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y))
        }
        func segment(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
            let vx = b.x - a.x, vy = b.y - a.y
            let len2 = vx * vx + vy * vy
            let t = len2 == 0 ? 0 : min(max(((c.x - a.x) * vx + (c.y - a.y) * vy) / len2, 0), 1)
            return ((a.x + t * vx - c.x) * (a.x + t * vx - c.x) + (a.y + t * vy - c.y) * (a.y + t * vy - c.y)).squareRoot()
        }
        switch kind {
        case .highlight, .redact, .mosaic:
            let r = rect()
            return c.x >= r.x0 - tolerance / 2 && c.x <= r.x1 + tolerance / 2 && c.y >= r.y0 - tolerance / 2 && c.y <= r.y1 + tolerance / 2
        case .box:
            let r = rect()
            let inOuter = c.x >= r.x0 - tolerance && c.x <= r.x1 + tolerance && c.y >= r.y0 - tolerance && c.y <= r.y1 + tolerance
            let inInner = c.x > r.x0 + tolerance && c.x < r.x1 - tolerance && c.y > r.y0 + tolerance && c.y < r.y1 - tolerance
            return inOuter && !inInner
        case .arrow:
            return segment(d(points[0]), d(points[points.count - 1])) <= tolerance * 1.4   // the shaft bows a little
        case .pen:
            let pts = points.map(d)
            return zip(pts, pts.dropFirst()).contains { segment($0, $1) <= tolerance }
        case .text:
            let o = d(points[0])
            let size = textSize ?? (w: 120, h: 30)
            return c.x >= o.x && c.x <= o.x + size.w && c.y >= o.y && c.y <= o.y + size.h
        }
    }

    /// The side of one mosaic block, in the same units as `width` and `height` (the
    /// region's size as drawn). Blocks are coarse on purpose: at least a quarter of the
    /// region's short side, so one line of text becomes a few blocks and cannot be read,
    /// but never smaller than 16 or larger than 40 style units.
    public static func mosaicCell(width: Double, height: Double, unit: Double) -> Double {
        let short = min(width, height)
        return min(max(short / 4, 16 * unit), max(40 * unit, 16 * unit))
    }

    /// Blocks across and down for a mosaic region.
    public static func mosaicGrid(width: Double, height: Double, unit: Double) -> (cols: Int, rows: Int) {
        let cell = mosaicCell(width: width, height: height, unit: unit)
        return (max(1, Int((width / cell).rounded(.up))), max(1, Int((height / cell).rounded(.up))))
    }
}

/// The editor's palette: soft pastels for marks, plus ink for text and redaction.
public enum PastelColor: String, Codable, CaseIterable {
    case pink, peach, butter, mint, sky, lilac, ink

    public var hex: UInt32 {
        switch self {
        case .pink: return 0xF7A8C8
        case .peach: return 0xFFC3A0
        case .butter: return 0xFBE38E
        case .mint: return 0x9FE2C8
        case .sky: return 0x9CCCF7
        case .lilac: return 0xC6B0F5
        case .ink: return 0x463F5C
        }
    }
}
