import XCTest
@testable import LauncherCore

final class CSVLogTests: XCTestCase {
    func testParseCommand() {
        XCTAssertEqual(CSVLog.parse("food banana split and hot dog")?.category, "food")
        XCTAssertEqual(CSVLog.parse("food banana split and hot dog")?.value, "banana split and hot dog")
        XCTAssertEqual(CSVLog.parse("Weight 225")?.category, "weight")
        XCTAssertEqual(CSVLog.parse("weight 225")?.value, "225")
        XCTAssertNil(CSVLog.parse("weight"))
        XCTAssertNil(CSVLog.parse("weight   "))
        XCTAssertNil(CSVLog.parse(""))
    }

    func testLineQuoting() {
        let e = CSVLog.Entry(date: "2026-09-15T12:00:00", category: "food", value: "eggs, \"fresh\"")
        let line = CSVLog.line(e)
        XCTAssertEqual(line, "2026-09-15T12:00:00,food,\"eggs, \"\"fresh\"\"\"")
        XCTAssertEqual(CSVLog.parseLine(line), e)
    }

    func testPlainLine() {
        let e = CSVLog.Entry(date: "2026-09-15T12:00:00", category: "weight", value: "225")
        XCTAssertEqual(CSVLog.line(e), "2026-09-15T12:00:00,weight,225")
        XCTAssertEqual(CSVLog.parseLine("2026-09-15T12:00:00,weight,225"), e)
    }

    func testTimestampHasOffsetAndDisplays() {
        let d = ISO8601DateFormatter().date(from: "2026-10-03T18:05:12Z")!
        XCTAssertEqual(CSVLog.timestamp(d, timeZone: TimeZone(identifier: "America/New_York")!), "2026-10-03T14:05:12-04:00")
        XCTAssertEqual(CSVLog.timestamp(d, timeZone: TimeZone(identifier: "UTC")!), "2026-10-03T18:05:12+00:00")
        XCTAssertEqual(CSVLog.display("2026-10-03T14:05:12-04:00"), "2026-10-03 14:05")
        XCTAssertEqual(CSVLog.display("2026-09-15T13:01:10"), "2026-09-15 13:01")
        XCTAssertEqual(CSVLog.display("garbage"), "garbage")
    }
}
