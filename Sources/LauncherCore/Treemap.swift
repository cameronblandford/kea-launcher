import Foundation

/// One block of the treemap, in pixels with the origin at the top left.
public struct TreemapCell {
    public enum Kind: UInt8 {
        case file
        /// A folder that is too small on screen to divide.
        case folder
        /// The files and folders of `node` that are each too small to show.
        case small
        /// The free space of the volume. It has no node (`node` is -1) and is drawn flat
        /// with diagonal lines.
        case free
    }

    public var node: Int32
    public var kind: Kind
    public var x, y, w, h: Double
    /// The cushion surface: height = sx2·x² + sx1·x + sy2·y² + sy1·y.
    public var sx1, sx2, sy1, sy2: Double

    /// The pixels the block covers. Neighbours share edges, so blocks do not overlap.
    public var pixels: (x0: Int, y0: Int, x1: Int, y1: Int) {
        (Int(x.rounded()), Int(y.rounded()), Int((x + w).rounded()), Int((y + h).rounded()))
    }
}

/// A folder that was divided, kept so the window can outline a selected folder.
public struct TreemapFolder {
    public var node: Int32
    public var x, y, w, h: Double
}

public struct TreemapLayout {
    public var width: Int
    public var height: Int
    public var cells: [TreemapCell] = []
    public var folders: [TreemapFolder] = []

    /// The index of the block at a pixel.
    public func cell(atX px: Int, y py: Int) -> Int? {
        cells.firstIndex { c in
            let p = c.pixels
            return px >= p.x0 && px < p.x1 && py >= p.y0 && py < p.y1
        }
    }

    /// The rectangle of a node: a file block, or the whole area of a folder.
    public func rect(of node: Int32) -> (x: Double, y: Double, w: Double, h: Double)? {
        if let f = folders.first(where: { $0.node == node }) { return (f.x, f.y, f.w, f.h) }
        if let c = cells.first(where: { $0.node == node && $0.kind != .small }) { return (c.x, c.y, c.w, c.h) }
        return nil
    }
}

/// A squarified cushion treemap (Bruls, Huizing and van Wijk; van Wijk and van de Wetering).
public enum Treemap {
    public typealias Rect = (x: Double, y: Double, w: Double, h: Double)

    /// Divides `rect` into one rectangle for each size, with areas in proportion to the
    /// sizes and sides as near to square as the order allows. `sizes` must be positive;
    /// largest first gives the best shapes.
    public static func squarify(_ sizes: [Double], in rect: Rect) -> [Rect] {
        let total = sizes.reduce(0, +)
        guard total > 0, rect.w > 0, rect.h > 0 else { return sizes.map { _ in (rect.x, rect.y, 0, 0) } }
        let scale = rect.w * rect.h / total
        var out: [Rect] = []
        out.reserveCapacity(sizes.count)
        var free = rect
        var i = 0
        while i < sizes.count {
            // Grow one row along the short side while its worst aspect ratio gets better.
            let side = min(free.w, free.h)
            var sum = sizes[i] * scale
            var smallest = sum, largest = sum
            var end = i + 1
            var worst = ratio(sum: sum, smallest: smallest, largest: largest, side: side)
            while end < sizes.count {
                let area = sizes[end] * scale
                let next = ratio(sum: sum + area, smallest: min(smallest, area), largest: max(largest, area), side: side)
                if next > worst { break }
                worst = next
                sum += area
                smallest = min(smallest, area)
                largest = max(largest, area)
                end += 1
            }
            // The last row takes what is left, so rounding never leaves a gap.
            let last = end == sizes.count
            if free.w >= free.h {
                // The row is a column at the left; items go from top to bottom.
                let t = last ? free.w : min(sum / side, free.w)
                var y = free.y
                for k in i ..< end {
                    let h = k == end - 1 ? free.y + free.h - y : sizes[k] * scale / sum * free.h
                    out.append((free.x, y, t, h))
                    y += h
                }
                free.x += t
                free.w -= t
            } else {
                let t = last ? free.h : min(sum / side, free.h)
                var x = free.x
                for k in i ..< end {
                    let w = k == end - 1 ? free.x + free.w - x : sizes[k] * scale / sum * free.w
                    out.append((x, free.y, w, t))
                    x += w
                }
                free.y += t
                free.h -= t
            }
            i = end
        }
        return out
    }

    private static func ratio(sum: Double, smallest: Double, largest: Double, side: Double) -> Double {
        let s2 = sum * sum, w2 = side * side
        return max(w2 * largest / s2, s2 / (w2 * smallest))
    }

    /// Lays out everything below `root` in a `width` × `height` pixel area. An item whose
    /// block would be smaller than `minSide` pixels square joins the "small" block of its
    /// folder, and a folder narrower than two blocks is not divided. `free` bytes, when not
    /// zero, get one block of their own beside everything else.
    public static func layout(_ tree: DiskTree, root: Int32, width: Int, height: Int, minSide: Double = 2,
                              ridge: Double = 0.22, falloff: Double = 0.7, blockRidge: Double = 0.3, free: UInt64 = 0) -> TreemapLayout {
        var layout = TreemapLayout(width: width, height: height)
        guard width > 0, height > 0, tree.size[Int(root)] > 0 else { return layout }
        var area: Rect = (0, 0, Double(width), Double(height))
        if free > 0 {
            // The larger of the two goes first, as in every other row of the map.
            let used = Double(tree.size[Int(root)])
            let parts = squarify(used >= Double(free) ? [used, Double(free)] : [Double(free), used], in: area)
            area = used >= Double(free) ? parts[0] : parts[1]
            let r = used >= Double(free) ? parts[1] : parts[0]
            layout.cells.append(TreemapCell(node: -1, kind: .free, x: r.x, y: r.y, w: r.w, h: r.h, sx1: 0, sx2: 0, sy1: 0, sy2: 0))
        }

        func place(_ node: Int32, _ r: Rect, _ surface: (Double, Double, Double, Double), _ h: Double) {
            // A block gets a full ridge at any depth, so each file reads as one cushion;
            // the ridges of the folders above it get weaker with depth.
            let divided = tree.isDirectory(node) && min(r.w, r.h) >= 2 * minSide && tree.childCount[Int(node)] > 0
            var s = surface
            addRidge(r.x, r.x + r.w, divided ? h : blockRidge, &s.0, &s.1)
            addRidge(r.y, r.y + r.h, divided ? h : blockRidge, &s.2, &s.3)
            func cell(_ kind: TreemapCell.Kind, _ id: Int32, _ rect: Rect, _ s: (Double, Double, Double, Double)) {
                layout.cells.append(TreemapCell(node: id, kind: kind, x: rect.x, y: rect.y, w: rect.w, h: rect.h,
                                                sx1: s.0, sx2: s.1, sy1: s.2, sy2: s.3))
            }
            guard tree.isDirectory(node) else { return cell(.file, node, r, s) }
            guard divided else { return cell(.folder, node, r, s) }

            layout.folders.append(TreemapFolder(node: node, x: r.x, y: r.y, w: r.w, h: r.h))
            let children = tree.children(of: node).filter { tree.size[Int($0)] > 0 }
                .sorted { tree.size[Int($0)] > tree.size[Int($1)] }
            let total = children.reduce(0.0) { $0 + Double(tree.size[Int($1)]) }
            guard total > 0 else { return }
            // Children are sorted, so everything after the first too-small one is too small.
            let threshold = minSide * minSide / (r.w * r.h) * total
            let cut = children.firstIndex { Double(tree.size[Int($0)]) < threshold } ?? children.count
            var sizes = children[..<cut].map { Double(tree.size[Int($0)]) }
            let rest = children[cut...].reduce(0.0) { $0 + Double(tree.size[Int($1)]) }
            if rest > 0 { sizes.append(rest) }
            let rects = squarify(sizes, in: r)
            for i in 0 ..< cut { place(children[i], rects[i], s, h * falloff) }
            if rest > 0 {
                var small = s
                let rr = rects[cut]
                addRidge(rr.x, rr.x + rr.w, blockRidge, &small.0, &small.1)
                addRidge(rr.y, rr.y + rr.h, blockRidge, &small.2, &small.3)
                cell(.small, node, rr, small)
            }
        }
        place(root, area, (0, 0, 0, 0), ridge)
        return layout
    }

    private static func addRidge(_ a: Double, _ b: Double, _ h: Double, _ s1: inout Double, _ s2: inout Double) {
        guard b - a > 0.001 else { return }
        s1 += 4 * h * (b + a) / (b - a)
        s2 -= 4 * h / (b - a)
    }

    /// Draws the layout as RGBA bytes (`width` × `height` × 4, opaque), with each block lit
    /// as a cushion from the top left. `colors` has one 0xRRGGBB value for each cell. The
    /// free-space block is flat in its color, with darker diagonal lines.
    public static func render(_ layout: TreemapLayout, colors: [UInt32]) -> [UInt8] {
        let width = layout.width, height = layout.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard !layout.cells.isEmpty else { return pixels }
        // Light direction (-1, -1, 10), normalized. The y axis points down.
        let norm = (102.0).squareRoot()
        let lx = -1 / norm, ly = -1 / norm, lz = 10 / norm
        // Brighter than plain shading, so a flat part of a block shows its true color.
        let ambient = 0.25, diffuse = 1.05
        let chunk = 2048
        let hatchPeriod = 16, hatchWidth = 2
        let chunks = (layout.cells.count + chunk - 1) / chunk
        pixels.withUnsafeMutableBufferPointer { out in
            let base = out.baseAddress!
            layout.cells.withUnsafeBufferPointer { cells in
                colors.withUnsafeBufferPointer { colors in
                    DispatchQueue.concurrentPerform(iterations: chunks) { part in
                        for i in part * chunk ..< min(cells.count, (part + 1) * chunk) {
                            let c = cells[i]
                            let p = c.pixels
                            let x0 = max(0, p.x0), x1 = min(width, p.x1), y0 = max(0, p.y0), y1 = min(height, p.y1)
                            guard x0 < x1, y0 < y1 else { continue }
                            let rgb = colors[i]
                            let r = Double((rgb >> 16) & 0xFF), g = Double((rgb >> 8) & 0xFF), b = Double(rgb & 0xFF)
                            if c.kind == .free {
                                for y in y0 ..< y1 {
                                    var o = base + (y * width + x0) * 4
                                    for x in x0 ..< x1 {
                                        let shade = (x + y) % hatchPeriod < hatchWidth ? 0.84 : 1.0
                                        o[0] = UInt8(r * shade)
                                        o[1] = UInt8(g * shade)
                                        o[2] = UInt8(b * shade)
                                        o[3] = 255
                                        o += 4
                                    }
                                }
                                continue
                            }
                            for y in y0 ..< y1 {
                                let ny = -(2 * c.sy2 * (Double(y) + 0.5) + c.sy1)
                                var o = base + (y * width + x0) * 4
                                for x in x0 ..< x1 {
                                    let nx = -(2 * c.sx2 * (Double(x) + 0.5) + c.sx1)
                                    let cosine = (nx * lx + ny * ly + lz) / (nx * nx + ny * ny + 1).squareRoot()
                                    let light = ambient + max(0, diffuse * cosine)
                                    o[0] = UInt8(min(255, r * light))
                                    o[1] = UInt8(min(255, g * light))
                                    o[2] = UInt8(min(255, b * light))
                                    o[3] = 255
                                    o += 4
                                }
                            }
                        }
                    }
                }
            }
        }
        return pixels
    }
}
