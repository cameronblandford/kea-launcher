import Foundation

/// The paint bucket of `paint`: fills the area of one color around a point.
public enum PaintFill {
    /// Fills from (`x`, `y`) over every connected pixel whose color is within `tolerance`
    /// of the color at that point, in a buffer of 4 bytes a pixel (red, green, blue, then
    /// one byte that is left alone), rows from the top. Lines drawn with smooth edges have
    /// a ring of blended pixels that the fill does not reach; those are mixed half and half
    /// with the new color so that no pale outline stays. Returns the count of filled pixels.
    @discardableResult
    public static func fill(_ pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int,
                            x: Int, y: Int, color: (r: UInt8, g: UInt8, b: UInt8), tolerance: Int = 40) -> Int {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        let seed = pixels + y * bytesPerRow + x * 4
        let sr = Int(seed[0]), sg = Int(seed[1]), sb = Int(seed[2])
        // Nothing to do when the area already has the color.
        if sr == Int(color.r), sg == Int(color.g), sb == Int(color.b) { return 0 }

        var filled = [Bool](repeating: false, count: width * height)
        func matches(_ px: Int, _ py: Int) -> Bool {
            if filled[py * width + px] { return false }
            let p = pixels + py * bytesPerRow + px * 4
            return abs(Int(p[0]) - sr) <= tolerance && abs(Int(p[1]) - sg) <= tolerance && abs(Int(p[2]) - sb) <= tolerance
        }
        func paint(_ px: Int, _ py: Int) {
            let p = pixels + py * bytesPerRow + px * 4
            p[0] = color.r
            p[1] = color.g
            p[2] = color.b
            filled[py * width + px] = true
        }

        // One run of a row at a time: fill the run, then queue the runs above and below it.
        var count = 0
        var stack = [(x, y)]
        while let (startX, row) = stack.popLast() {
            guard matches(startX, row) else { continue }
            var left = startX
            while left > 0, matches(left - 1, row) { left -= 1 }
            var right = startX
            while right < width - 1, matches(right + 1, row) { right += 1 }
            for px in left ... right { paint(px, row) }
            count += right - left + 1
            for next in [row - 1, row + 1] where next >= 0 && next < height {
                var px = left
                while px <= right {
                    if matches(px, next) {
                        stack.append((px, next))
                        while px <= right, matches(px, next) { px += 1 }
                    } else {
                        px += 1
                    }
                }
            }
        }

        // The ring: a pixel that was not filled but touches the fill.
        var ring: [Int] = []
        for py in 0 ..< height {
            for px in 0 ..< width where !filled[py * width + px] {
                if (px > 0 && filled[py * width + px - 1]) || (px < width - 1 && filled[py * width + px + 1])
                    || (py > 0 && filled[(py - 1) * width + px]) || (py < height - 1 && filled[(py + 1) * width + px]) {
                    ring.append(py * width + px)
                }
            }
        }
        for index in ring {
            let p = pixels + (index / width) * bytesPerRow + (index % width) * 4
            p[0] = UInt8((Int(p[0]) + Int(color.r)) / 2)
            p[1] = UInt8((Int(p[1]) + Int(color.g)) / 2)
            p[2] = UInt8((Int(p[2]) + Int(color.b)) / 2)
        }
        return count
    }
}
