import XCTest
@testable import LauncherCore

final class SnippetsTests: XCTestCase {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }
    // 2026-10-04 15:07 in New York.
    var now: Date { ISO8601DateFormatter().date(from: "2026-10-04T19:07:00Z")! }

    func testExpand() {
        XCTAssertEqual(Snippets.expand("{date}", now: now, calendar: cal), "2026-10-04")
        XCTAssertEqual(Snippets.expand("{date+1}", now: now, calendar: cal), "2026-10-05")
        XCTAssertEqual(Snippets.expand("{date-4}", now: now, calendar: cal), "2026-09-30")
        XCTAssertEqual(Snippets.expand("at {time} on {date}!", now: now, calendar: cal), "at 15:07 on 2026-10-04!")
        XCTAssertEqual(Snippets.expand("{clipboard} / {nope} / {date+x}", now: now, calendar: cal, clipboard: "abc"), "abc / {nope} / {date+x}")
        XCTAssertEqual(Snippets.expand("no braces, and a lone { here", now: now, calendar: cal), "no braces, and a lone { here")
        // A brace that opens no placeholder does not hide the placeholder after it.
        XCTAssertEqual(Snippets.expand("{ \"d\": \"{date}\" }", now: now, calendar: cal), "{ \"d\": \"2026-10-04\" }")
        XCTAssertEqual(Snippets.expand("{{date}}", now: now, calendar: cal), "{2026-10-04}")
    }

    func testBufferFindsTriggers() {
        var b = Snippets.Buffer(triggers: [";td", ";tdx", ";sig"])
        XCTAssertNil(b.type("h"))
        XCTAssertNil(b.type(";"))
        XCTAssertNil(b.type("t"))
        XCTAssertEqual(b.type("d"), ";td")
        XCTAssertNil(b.type("x"), "the buffer was cleared, so ;tdx does not fire after ;td did")
        // Backspace removes the last character.
        XCTAssertNil(b.type(";si"))
        b.backspace()
        XCTAssertNil(b.type("g"))          // ";sg"
        // Reset forgets a half-typed trigger.
        XCTAssertNil(b.type(";si"))
        b.reset()
        XCTAssertNil(b.type("g"))
        XCTAssertEqual(b.type(";sig"), ";sig")
        var empty = Snippets.Buffer(triggers: [])
        XCTAssertNil(empty.type("anything"))
    }

    func testParseNew() {
        XCTAssertEqual(Snippets.parseNew(";sig Best, Sam")?.trigger, ";sig")
        XCTAssertEqual(Snippets.parseNew(";sig Best, Sam")?.expansion, "Best, Sam")
        XCTAssertNil(Snippets.parseNew(";sig"))
        XCTAssertNil(Snippets.parseNew("; x"))
    }

    func testLayoutFractionsRoundTrip() {
        let area = CGRect(x: 1512, y: 25, width: 2560, height: 1415)
        let window = CGRect(x: 1512 + 1280, y: 25, width: 1280, height: 707)
        let f = WindowLayouts.fractions(of: window, in: area)
        XCTAssertEqual(f[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(f[2], 0.5, accuracy: 0.001)
        // The same shares on a smaller display.
        let small = CGRect(x: 0, y: 25, width: 1512, height: 944)
        XCTAssertEqual(WindowLayouts.rect(f, in: small).minX, 756, accuracy: 1)
        XCTAssertEqual(WindowLayouts.rect(f, in: small).width, 756, accuracy: 1)
        XCTAssertEqual(WindowLayouts.displayIndex(for: window, areas: [small, area]), 1)
        XCTAssertNil(WindowLayouts.displayIndex(for: CGRect(x: 9000, y: 9000, width: 10, height: 10), areas: [small, area]))
    }
}
