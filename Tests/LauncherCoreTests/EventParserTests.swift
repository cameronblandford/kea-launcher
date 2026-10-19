import XCTest
@testable import LauncherCore

final class EventParserTests: XCTestCase {
    let cal = Calendar.current

    func hour(_ d: Date) -> Int { cal.component(.hour, from: d) }
    func minute(_ d: Date) -> Int { cal.component(.minute, from: d) }
    func daysFromToday(_ d: Date) -> Int {
        cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? -99
    }

    func testTomorrowAtFivePShorthand() {
        let p = EventParser.parse("go to alex's tomorrow at 5p")!
        XCTAssertEqual(p.title, "Go to alex's")
        XCTAssertEqual(daysFromToday(p.start), 1)
        XCTAssertEqual(hour(p.start), 17)
        XCTAssertFalse(p.allDay)
        XCTAssertEqual(p.end.timeIntervalSince(p.start), 3600)
    }

    func testExplicitRangeSetsDuration() {
        let p = EventParser.parse("dentist tomorrow 2-3:30pm")!
        XCTAssertEqual(p.title, "Dentist")
        XCTAssertEqual(hour(p.start), 14)
        XCTAssertEqual(p.end.timeIntervalSince(p.start), 90 * 60)
    }

    func testForDuration() {
        let p = EventParser.parse("deep work tomorrow at 9am for 2h")!
        XCTAssertEqual(p.title, "Deep work")
        XCTAssertEqual(hour(p.start), 9)
        XCTAssertEqual(p.end.timeIntervalSince(p.start), 7200)
    }

    func testAllDayWhenNoTime() {
        let p = EventParser.parse("mom's birthday next friday")!
        XCTAssertEqual(p.title, "Mom's birthday")
        XCTAssertTrue(p.allDay)
        XCTAssertEqual(hour(p.start), 0)
        XCTAssertEqual(p.end.timeIntervalSince(p.start), 86400)
    }

    func testNoonAndAbbreviations() {
        let p = EventParser.parse("lunch w/ sam thurs at noon")!
        XCTAssertEqual(p.title, "Lunch w/ sam")
        XCTAssertEqual(hour(p.start), 12)
        XCTAssertFalse(p.allDay)
    }

    func testTonightAndTmrw() {
        XCTAssertEqual(EventParser.parse("call dad tmrw at 7pm")?.title, "Call dad")
        XCTAssertEqual(EventParser.parse("call dad tmrw at 7pm").map { hour($0.start) }, 19)
        XCTAssertEqual(EventParser.parse("call dad tmrw at 7pm").map { daysFromToday($0.start) }, 1)
    }

    func testDateOnly() {
        let p = EventParser.parse("standup sept 20 at 10:30am")!
        XCTAssertEqual(p.title, "Standup")
        XCTAssertEqual(hour(p.start), 10)
        XCTAssertEqual(minute(p.start), 30)
        XCTAssertEqual(cal.component(.month, from: p.start), 9)
        XCTAssertEqual(cal.component(.day, from: p.start), 20)
    }

    func testNoDateReturnsNil() {
        XCTAssertNil(EventParser.parse("go to alex's"))
        XCTAssertNil(EventParser.parse(""))
    }

    func testTitleOnlyDateReturnsNil() {
        XCTAssertNil(EventParser.parse("tomorrow at 5pm"))
    }

    func testDurationExtraction() {
        let (rest, secs) = EventParser.extractDuration("gym tomorrow for 45 min")
        XCTAssertEqual(secs, 2700)
        XCTAssertEqual(rest.trimmingCharacters(in: .whitespaces), "gym tomorrow")
    }
}
