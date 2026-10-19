import XCTest
@testable import LauncherCore

final class MarkupTests: XCTestCase {

    func testMosaicBlocksAreCoarse() {
        // A line of text 24 units tall: the block is at least 16, so at most 2 rows.
        XCTAssertEqual(Markup.mosaicCell(width: 300, height: 24, unit: 1), 16)
        XCTAssertEqual(Markup.mosaicGrid(width: 300, height: 24, unit: 1).rows, 2)
        // A big region: a quarter of the short side, capped at 40.
        XCTAssertEqual(Markup.mosaicCell(width: 400, height: 120, unit: 1), 30)
        XCTAssertEqual(Markup.mosaicCell(width: 900, height: 600, unit: 1), 40)
        XCTAssertEqual(Markup.mosaicGrid(width: 900, height: 600, unit: 1).cols, 23)
        // Sizes follow the style unit, so a large image gets proportionally large blocks.
        XCTAssertEqual(Markup.mosaicCell(width: 300, height: 24, unit: 2), 32)
        XCTAssertEqual(Markup.mosaicGrid(width: 1, height: 1, unit: 1).cols, 1)
    }

    func testMarksRoundTripAsJSON() throws {
        let m = [Markup(kind: .arrow, points: [.init(0.1, 0.2), .init(0.3, 0.4)], color: .lilac)]
        let back = try JSONDecoder().decode([Markup].self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
    }

    func testMovedStaysInsideTheImage() {
        let m = Markup(kind: .redact, points: [.init(0.2, 0.3), .init(0.5, 0.6)])
        let near = m.moved(dx: 0.1, dy: -0.1)
        XCTAssertEqual(near.points[0].x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(near.points[0].y, 0.2, accuracy: 1e-9)
        XCTAssertEqual(near.points[1].x, 0.6, accuracy: 1e-9)
        XCTAssertEqual(near.points[1].y, 0.5, accuracy: 1e-9)
        let far = m.moved(dx: 2, dy: -2)
        XCTAssertEqual(far.points[1].x, 1, accuracy: 1e-9)       // right edge stops at the image edge
        XCTAssertEqual(far.points[0].x, 0.7, accuracy: 1e-9)     // and the size is kept
        XCTAssertEqual(far.points[0].y, 0, accuracy: 1e-9)
        XCTAssertEqual(far.points[1].y, 0.3, accuracy: 1e-9)
    }

    func testHitTesting() {
        // A 1000 x 500 drawing, tolerance 10 points.
        func hit(_ m: Markup, _ x: Double, _ y: Double) -> Bool { m.hit(.init(x, y), width: 1000, height: 500, tolerance: 10) }
        let fill = Markup(kind: .mosaic, points: [.init(0.2, 0.2), .init(0.4, 0.6)])
        XCTAssertTrue(hit(fill, 0.3, 0.4))
        XCTAssertFalse(hit(fill, 0.5, 0.4))
        // A box takes its outline, not its inside.
        let box = Markup(kind: .box, points: [.init(0.2, 0.2), .init(0.6, 0.8)])
        XCTAssertTrue(hit(box, 0.2, 0.5))
        XCTAssertTrue(hit(box, 0.4, 0.8))
        XCTAssertFalse(hit(box, 0.4, 0.5))
        XCTAssertFalse(hit(box, 0.7, 0.5))
        // An arrow takes a band around its line.
        let arrow = Markup(kind: .arrow, points: [.init(0.1, 0.1), .init(0.5, 0.1)])
        XCTAssertTrue(hit(arrow, 0.3, 0.11))
        XCTAssertFalse(hit(arrow, 0.3, 0.2))
        XCTAssertFalse(hit(arrow, 0.7, 0.1))
        let pen = Markup(kind: .pen, points: [.init(0.1, 0.5), .init(0.2, 0.6), .init(0.3, 0.5)])
        XCTAssertTrue(hit(pen, 0.15, 0.55))
        XCTAssertFalse(hit(pen, 0.2, 0.3))
        let text = Markup(kind: .text, points: [.init(0.5, 0.5)], text: "hi")
        XCTAssertTrue(text.hit(.init(0.55, 0.52), width: 1000, height: 500, tolerance: 10, textSize: (w: 100, h: 30)))
        XCTAssertFalse(text.hit(.init(0.7, 0.52), width: 1000, height: 500, tolerance: 10, textSize: (w: 100, h: 30)))
    }
}
