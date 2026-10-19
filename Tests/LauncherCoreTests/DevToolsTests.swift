import XCTest
@testable import LauncherCore

final class DevToolsTests: XCTestCase {
    func testBase64AndURL() {
        XCTAssertEqual(DevTools.base64Encode("hello, kea"), "aGVsbG8sIGtlYQ==")
        XCTAssertEqual(DevTools.base64Decode("aGVsbG8sIGtlYQ=="), "hello, kea")
        XCTAssertEqual(DevTools.base64Decode("aGVsbG8sIGtlYQ"), "hello, kea")   // padding optional
        XCTAssertNil(DevTools.base64Decode("not base64!"))
        XCTAssertEqual(DevTools.urlEncode("a b&c=d/é"), "a%20b%26c%3Dd%2F%C3%A9")
        XCTAssertEqual(DevTools.urlDecode("a%20b%26c"), "a b&c")
        XCTAssertNil(DevTools.urlDecode("plain"))
    }

    func testHashes() {
        let h = Dictionary(uniqueKeysWithValues: DevTools.hashes("abc").map { ($0.name, $0.hex) })
        XCTAssertEqual(h["MD5"], "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(h["SHA-1"], "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(h["SHA-256"], "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testJSON() {
        let j = DevTools.json(#"{"b":[1,2],"a":{"x":"y/z"}}"#)!
        XCTAssertEqual(j.minified, #"{"a":{"x":"y/z"},"b":[1,2]}"#)
        XCTAssertTrue(j.pretty.contains("\n  \"a\": {"))
        XCTAssertNil(DevTools.json("{nope"))
        XCTAssertNil(DevTools.json("42"))
    }

    func testColor() {
        XCTAssertEqual(DevTools.parseColor("#f80"), .init(255, 136, 0))
        XCTAssertEqual(DevTools.parseColor("FF8800"), .init(255, 136, 0))
        XCTAssertEqual(DevTools.parseColor("rgb(255, 136, 0)"), .init(255, 136, 0))
        XCTAssertEqual(DevTools.parseColor("255 136 0")?.hex, "#FF8800")
        XCTAssertNil(DevTools.parseColor("300 0 0"))
        XCTAssertNil(DevTools.parseColor("hello"))
        XCTAssertEqual(DevTools.RGB(255, 136, 0).hsl, "hsl(32, 100%, 50%)")
        XCTAssertEqual(DevTools.RGB(128, 128, 128).hsl, "hsl(0, 0%, 50%)")
        XCTAssertEqual(DevTools.RGB(255, 136, 0).css, "rgb(255, 136, 0)")
    }
}

final class ZoneTimesTests: XCTestCase {
    let ny = TimeZone(identifier: "America/New_York")!
    // 2026-10-04 12:00 in New York (EDT, UTC-4).
    var noon: Date { ISO8601DateFormatter().date(from: "2026-10-04T16:00:00Z")! }

    func testZones() {
        XCTAssertEqual(ZoneTimes.zone("pst")?.identifier, "America/Los_Angeles")
        XCTAssertEqual(ZoneTimes.zone("Tokyo")?.identifier, "Asia/Tokyo")
        XCTAssertEqual(ZoneTimes.zone("new york")?.identifier, "America/New_York")
        XCTAssertEqual(ZoneTimes.zone("here", local: ny)?.identifier, "America/New_York")
        XCTAssertNil(ZoneTimes.zone("narnia"))
    }

    func testClock() {
        XCTAssertEqual(ZoneTimes.clock("3pm")?.h, 15)
        XCTAssertEqual(ZoneTimes.clock("3:30 pm")?.m, 30)
        XCTAssertEqual(ZoneTimes.clock("12am")?.h, 0)
        XCTAssertEqual(ZoneTimes.clock("15:30")?.h, 15)
        XCTAssertEqual(ZoneTimes.clock("noon")?.h, 12)
        XCTAssertNil(ZoneTimes.clock("3"))
        XCTAssertNil(ZoneTimes.clock("25:00"))
        XCTAssertNil(ZoneTimes.clock("13pm"))
    }

    func testConvert() {
        let a = ZoneTimes.convert("3pm pst in nyc", now: noon, local: ny)!
        XCTAssertEqual(a.time, "6:00 PM")
        XCTAssertEqual(a.place, "NYC")
        XCTAssertEqual(a.dayNote, "")
        XCTAssertEqual(a.source, "3:00 PM in PST")
        // No source zone means the local one.
        XCTAssertEqual(ZoneTimes.convert("9am in london", now: noon, local: ny)?.time, "2:00 PM")
        // Across the date line.
        let t = ZoneTimes.convert("8pm nyc to tokyo", now: noon, local: ny)!
        XCTAssertEqual(t.time, "9:00 AM")
        XCTAssertEqual(t.dayNote, "tomorrow")
        XCTAssertEqual(t.place, "Tokyo")
    }

    func testNow() {
        let a = ZoneTimes.convert("time in tokyo", now: noon, local: ny)!
        XCTAssertEqual(a.time, "1:00 AM")
        XCTAssertEqual(a.dayNote, "tomorrow")
        XCTAssertEqual(ZoneTimes.convert("london time", now: noon, local: ny)?.time, "5:00 PM")
        XCTAssertNil(ZoneTimes.convert("time in narnia", now: noon, local: ny))
        XCTAssertNil(ZoneTimes.convert("log in to github", now: noon, local: ny))
        XCTAssertNil(ZoneTimes.convert("10 mi in km", now: noon, local: ny))
    }
}
