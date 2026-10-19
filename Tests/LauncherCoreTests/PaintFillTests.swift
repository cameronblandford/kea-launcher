import XCTest
@testable import LauncherCore

final class PaintFillTests: XCTestCase {
    /// A picture from rows of characters: `.` white, `#` black, `g` mid gray, `p` pale gray.
    private func picture(_ rows: [String]) -> (pixels: [UInt8], width: Int, height: Int) {
        let width = rows[0].count
        var pixels: [UInt8] = []
        for row in rows {
            for c in row {
                let v: UInt8 = c == "#" ? 0 : c == "g" ? 128 : c == "p" ? 235 : 255
                pixels += [v, v, v, 255]
            }
        }
        return (pixels, width, rows.count)
    }

    private func fill(_ rows: [String], x: Int, y: Int, tolerance: Int = 40) -> (rows: [String], count: Int) {
        var p = picture(rows)
        let (width, height) = (p.width, p.height)
        let count = p.pixels.withUnsafeMutableBufferPointer {
            PaintFill.fill($0.baseAddress!, width: width, height: height, bytesPerRow: width * 4, x: x, y: y, color: (255, 0, 0), tolerance: tolerance)
        }
        let out = (0 ..< height).map { row in
            String((0 ..< width).map { col -> Character in
                let i = (row * width + col) * 4
                let (r, g, b) = (p.pixels[i], p.pixels[i + 1], p.pixels[i + 2])
                XCTAssertEqual(p.pixels[i + 3], 255, "the fourth byte is not touched")
                if (r, g, b) == (255, 0, 0) { return "R" }
                if (r, g, b) == (255, 255, 255) { return "." }
                if (r, g, b) == (0, 0, 0) { return "#" }
                return "~"                                   // a blended ring pixel
            })
        }
        return (out, count)
    }

    func testFillStaysInsideAClosedShape() {
        let out = fill(["#####..",
                        "#...#..",
                        "#...#..",
                        "#####.."], x: 2, y: 1, tolerance: 0)
        XCTAssertEqual(out.count, 6)
        // The border pixels that share an edge with the fill are the ring, mixed with red.
        // The corners touch the fill only diagonally and stay black.
        XCTAssertEqual(out.rows, ["#~~~#..",
                                  "~RRR~..",
                                  "~RRR~..",
                                  "#~~~#.."])
    }

    func testFillLeaksThroughAGapButNotDiagonally() {
        let out = fill(["..#.",
                        ".#..",
                        "#..."], x: 0, y: 0, tolerance: 0)
        // The two white pixels at the top left touch only by an edge to each other; the
        // area at the bottom right touches them only by corners.
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.rows[2].suffix(3), "...")
    }

    func testToleranceTakesNearColorsOnly() {
        let rows = ["..pg#"]
        XCTAssertEqual(fill(rows, x: 0, y: 0, tolerance: 40).count, 3, "pale gray is near white; mid gray is not")
        XCTAssertEqual(fill(rows, x: 0, y: 0, tolerance: 0).count, 2)
    }

    func testFillOfTheSameColorAndOutsideThePicture() {
        var p = picture(["...."])
        let count = p.pixels.withUnsafeMutableBufferPointer {
            PaintFill.fill($0.baseAddress!, width: 4, height: 1, bytesPerRow: 16, x: 1, y: 0, color: (255, 255, 255))
        }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(fill(["...."], x: 9, y: 0).count, 0)
        XCTAssertEqual(fill(["...."], x: 0, y: -1).count, 0)
    }

    func testLargeAreaDoesNotOverflow() {
        let out = fill([String](repeating: String(repeating: ".", count: 400), count: 300), x: 200, y: 150)
        XCTAssertEqual(out.count, 400 * 300)
    }
}
