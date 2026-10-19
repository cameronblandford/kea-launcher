import XCTest
@testable import LauncherCore

final class DurationParserTests: XCTestCase {
    func secs(_ s: String) -> TimeInterval? { DurationParser.parse(s)?.seconds }

    func testUnits() {
        XCTAssertEqual(secs("5m"), 300)
        XCTAssertEqual(secs("5min"), 300)
        XCTAssertEqual(secs("5 minutes"), 300)
        XCTAssertEqual(secs("90s"), 90)
        XCTAssertEqual(secs("45 seconds"), 45)
        XCTAssertEqual(secs("2h"), 7200)
        XCTAssertEqual(secs("1 hour"), 3600)
    }

    func testCompound() {
        XCTAssertEqual(secs("2h5m"), 7500)
        XCTAssertEqual(secs("1h 30m"), 5400)
        XCTAssertEqual(secs("1h30m10s"), 5410)
    }

    func testDecimal() {
        XCTAssertEqual(secs("2.5h"), 9000)
        XCTAssertEqual(secs("1.5m"), 90)
        XCTAssertEqual(secs("2.5hrs"), 9000)
    }

    func testBareNumberIsMinutes() {
        XCTAssertEqual(secs("10"), 600)
        XCTAssertEqual(secs("2.5"), 150)
    }

    func testLabel() {
        let p = DurationParser.parse("5m tea")!
        XCTAssertEqual(p.seconds, 300)
        XCTAssertEqual(p.label, "tea")
        XCTAssertEqual(DurationParser.parse("1h 30m  stand up")!.label, "stand up")
        XCTAssertEqual(DurationParser.parse("10 laundry")!.label, "laundry")
        XCTAssertEqual(DurationParser.parse("5m")!.label, "")
    }

    func testInvalid() {
        XCTAssertNil(DurationParser.parse(""))
        XCTAssertNil(DurationParser.parse("tea"))
        XCTAssertNil(DurationParser.parse("0m"))
        XCTAssertNil(DurationParser.parse("5x"))
    }

    func testFormatting() {
        XCTAssertEqual(DurationParser.format(4 * 60 + 32), "4:32")
        XCTAssertEqual(DurationParser.format(3600 + 5 * 60), "1:05:00")
        XCTAssertEqual(DurationParser.format(12), "12s")
        XCTAssertEqual(DurationParser.describe(300), "5m")
        XCTAssertEqual(DurationParser.describe(9000), "2h30m")
        XCTAssertEqual(DurationParser.describe(90), "1m30s")
        XCTAssertEqual(DurationParser.describe(45), "45s")
    }
}
