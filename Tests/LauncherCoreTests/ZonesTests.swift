import XCTest
@testable import LauncherCore

final class ZonesTests: XCTestCase {
    let unit = CGRect(x: 0, y: 0, width: 100, height: 100)

    func testShorthands() throws {
        XCTAssertEqual(try ZoneLayout.parse("cols 2").rects(in: unit),
                       [CGRect(x: 0, y: 0, width: 50, height: 100), CGRect(x: 50, y: 0, width: 50, height: 100)])
        XCTAssertEqual(try ZoneLayout.parse("rows 3").rects(in: CGRect(x: 0, y: 0, width: 30, height: 30)).map(\.minY), [0, 10, 20])
        XCTAssertEqual(try ZoneLayout.parse("zone").rects(in: unit), [unit])
    }

    func testNestedLayoutInReadingOrder() throws {
        let rects = try ZoneLayout.parse("cols(zone, rows 2)").rects(in: unit)
        XCTAssertEqual(rects, [CGRect(x: 0, y: 0, width: 50, height: 100),
                               CGRect(x: 50, y: 0, width: 50, height: 50),
                               CGRect(x: 50, y: 50, width: 50, height: 50)])
    }

    func testWeights() throws {
        let rects = try ZoneLayout.parse("cols(2*zone, zone)").rects(in: CGRect(x: 0, y: 0, width: 90, height: 10))
        XCTAssertEqual(rects.map(\.width), [60, 30])
    }

    func testBadLayouts() {
        XCTAssertThrowsError(try ZoneLayout.parse("cols"))
        XCTAssertThrowsError(try ZoneLayout.parse("cols(zone"))
        XCTAssertThrowsError(try ZoneLayout.parse("grid 2"))
        XCTAssertThrowsError(try ZoneLayout.parse("zone zone"))
    }

    /// A sample setup: portrait monitor on the left, laptop in the middle, wide monitor on the right.
    func cams() throws -> [CGRect] {
        ZoneNavigator.globalZones(displays: [
            (CGRect(x: 1512, y: 0, width: 2560, height: 1440), try ZoneLayout.parse("cols(zone, rows 2)")),
            (CGRect(x: 0, y: 0, width: 1512, height: 982), try ZoneLayout.parse("cols 2")),
            (CGRect(x: -1080, y: -400, width: 1080, height: 1920), try ZoneLayout.parse("rows 3")),
        ], gap: 0)
    }

    func testLoopOrderGoesLeftToRightAcrossDisplays() throws {
        let z = try cams()
        XCTAssertEqual(z.count, 8)
        XCTAssertEqual(z.map(\.minX), [-1080, -1080, -1080, 0, 756, 1512, 2792, 2792])
        var i = 0
        var visited: [Int] = []
        for _ in 0..<8 { i = ZoneNavigator.target(from: i, .right, zones: z)!; visited.append(i) }
        XCTAssertEqual(visited, [1, 2, 3, 4, 5, 6, 7, 0])
        XCTAssertEqual(ZoneNavigator.target(from: 0, .left, zones: z), 7)
    }

    func testUpDownStaysInColumnAndWraps() throws {
        let z = try cams()
        XCTAssertEqual(ZoneNavigator.target(from: 0, .down, zones: z), 1)
        XCTAssertEqual(ZoneNavigator.target(from: 2, .down, zones: z), 0)
        XCTAssertEqual(ZoneNavigator.target(from: 0, .up, zones: z), 2)
        XCTAssertEqual(ZoneNavigator.target(from: 6, .down, zones: z), 7)
        XCTAssertNil(ZoneNavigator.target(from: 3, .up, zones: z))  // laptop half, nothing above
        XCTAssertNil(ZoneNavigator.target(from: 5, .down, zones: z)) // wide monitor's full-height left zone
    }

    func testGapInsetsEveryEdgeEvenly() {
        let z = ZoneNavigator.globalZones(displays: [(unit, .split(vertical: false, [(1, .zone), (1, .zone)]))], gap: 10)
        XCTAssertEqual(z, [CGRect(x: 10, y: 10, width: 35, height: 80), CGRect(x: 55, y: 10, width: 35, height: 80)])
    }

    func testLocate() throws {
        let z = try cams()
        // A terminal that snaps to its cell grid is a little smaller than the zone.
        let t = z[4].insetBy(dx: 6, dy: 9)
        XCTAssertEqual(ZoneNavigator.locate(t, in: z)!.index, 4)
        XCTAssertTrue(ZoneNavigator.locate(t, in: z)!.snapped)
        // A window across the whole laptop is not snapped to either half.
        let wide = ZoneNavigator.locate(CGRect(x: 100, y: 100, width: 1300, height: 700), in: z)!
        XCTAssertFalse(wide.snapped)
        XCTAssertTrue([3, 4].contains(wide.index))
    }

    func testUnsnappedStartsAtFirstZoneOfItsDisplay() throws {
        let wide = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let portrait = CGRect(x: -1080, y: -400, width: 1080, height: 1920)
        let z = try cams()
        let big = CGRect(x: 1700, y: 100, width: 2200, height: 1200)
        let start = ZoneNavigator.entry(for: big, displays: [laptop, wide, portrait], zones: z)!
        XCTAssertEqual(start, 5) // left zone of the wide monitor
        // One display with cols(zone, rows 2): Left from an unsnapped window goes 1, 3, 2.
        let one = ZoneNavigator.globalZones(displays: [(wide, try ZoneLayout.parse("cols(zone, rows 2)"))], gap: 0)
        var i = ZoneNavigator.entry(for: big, displays: [wide], zones: one)!
        var seen = [i]
        for _ in 0..<2 { i = ZoneNavigator.target(from: i, .left, zones: one)!; seen.append(i) }
        XCTAssertEqual(seen, [0, 2, 1])
        // Right from a maximized window starts on the right edge: top right, then bottom right.
        XCTAssertEqual(ZoneNavigator.entry(for: wide, .right, displays: [wide], zones: one), 1)
        let halves = ZoneNavigator.globalZones(displays: [(laptop, try ZoneLayout.parse("cols 2"))], gap: 8)
        XCTAssertEqual(ZoneNavigator.entry(for: laptop, .right, displays: [laptop], zones: halves), 1)
        XCTAssertEqual(ZoneNavigator.entry(for: laptop, .left, displays: [laptop], zones: halves), 0)
        XCTAssertEqual(ZoneNavigator.entry(for: CGRect(x: 10, y: 10, width: 1400, height: 900), displays: [laptop, wide, portrait], zones: z), 3)
    }
}

final class ZoneDropTests: XCTestCase {
    // Two displays side by side. The left one has two columns; the right one has a
    // column and two rows, as in the default layouts. The gap between zones is 8.
    private let displays = [CGRect(x: 0, y: 0, width: 1000, height: 600), CGRect(x: 1000, y: 0, width: 2000, height: 1000)]
    private let zones = [CGRect(x: 8, y: 8, width: 488, height: 584), CGRect(x: 504, y: 8, width: 488, height: 584),
                         CGRect(x: 1008, y: 8, width: 988, height: 984), CGRect(x: 2004, y: 8, width: 988, height: 488), CGRect(x: 2004, y: 504, width: 988, height: 488)]

    private func targets(_ x: CGFloat, _ y: CGFloat) -> [Int] { ZoneDrop.targets(at: CGPoint(x: x, y: y), zones: zones, displays: displays) }

    func testInsideOneZone() {
        XCTAssertEqual(targets(200, 300), [0])
        XCTAssertEqual(targets(800, 300), [1])
        XCTAssertEqual(targets(1500, 500), [2])
        XCTAssertEqual(targets(2500, 900), [4])
    }

    func testNearABorderSpansTheZones() {
        XCTAssertEqual(targets(500, 300), [0, 1], "on the border of the two columns")
        XCTAssertEqual(targets(480, 300), [0, 1], "a little inside the left column")
        XCTAssertEqual(targets(440, 300), [0], "far enough inside")
        XCTAssertEqual(targets(2500, 500), [3, 4], "between the two rows")
        XCTAssertEqual(targets(2000, 200), [2, 3])
        XCTAssertEqual(targets(2000, 500), [2, 3, 4], "where three zones meet")
    }

    func testZonesOfAnotherDisplayDoNotJoin() {
        // 990 is on the left display, 18 points from the first zone of the right display.
        XCTAssertEqual(targets(990, 300), [1])
        XCTAssertEqual(targets(1004, 300), [2])
    }

    func testOutsideEveryZoneTakesTheNearest() {
        let wide = ZoneDrop.targets(at: CGPoint(x: 995, y: 300), zones: zones, displays: displays, margin: 0)
        XCTAssertEqual(wide, [1], "in the gap at the edge of the display")
        XCTAssertTrue(targets(5000, 300).isEmpty, "not on a display")
        XCTAssertTrue(ZoneDrop.targets(at: CGPoint(x: 10, y: 10), zones: [], displays: displays).isEmpty)
    }

    func testFrameOfSeveralZones() {
        XCTAssertEqual(ZoneDrop.frame(of: [0], zones: zones), zones[0])
        XCTAssertEqual(ZoneDrop.frame(of: [0, 1], zones: zones), CGRect(x: 8, y: 8, width: 984, height: 584))
        XCTAssertEqual(ZoneDrop.frame(of: [2, 3, 4], zones: zones), CGRect(x: 1008, y: 8, width: 1984, height: 984))
        XCTAssertNil(ZoneDrop.frame(of: [], zones: zones))
        XCTAssertNil(ZoneDrop.frame(of: [9], zones: zones))
    }

    func testWindowDragIsToldFromOtherDrags() {
        let w = CGRect(x: 100, y: 100, width: 800, height: 600)
        func drag(_ after: CGRect, _ dx: CGFloat, _ dy: CGFloat) -> Bool {
            ZoneDrop.isWindowDrag(windowBefore: w, windowAfter: after, pointerBefore: CGPoint(x: 400, y: 110), pointerAfter: CGPoint(x: 400 + dx, y: 110 + dy))
        }
        XCTAssertTrue(drag(w.offsetBy(dx: 40, dy: 25), 40, 25), "the window follows the pointer")
        XCTAssertTrue(drag(w.offsetBy(dx: 38, dy: 27), 40, 25), "a little behind is the same")
        XCTAssertFalse(drag(w, 40, 25), "the window stays: a selection or a file drag")
        XCTAssertFalse(drag(CGRect(x: 140, y: 100, width: 760, height: 600), 40, 0), "the left edge moves and the size changes: a resize")
        XCTAssertFalse(drag(w.offsetBy(dx: 40, dy: 25), -40, 90), "the window moved another way than the pointer")
    }
}
