import XCTest
@testable import LauncherCore

final class AutoClickTests: XCTestCase {
    func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    func testDefaultsMatchHammerspoon() throws {
        let c = try decode("{}").autoclick
        XCTAssertEqual(c.hotkey, "control+option+command+c")
        XCTAssertEqual(c.interval, 0.02)
        XCTAssertEqual(c.effectiveInterval, 0.02)
        XCTAssertNoThrow(try HotKeySpec.parse(c.hotkey))
    }

    func testConfigKeysAndWrongTypes() throws {
        let c = try decode(#"{"autoclick": {"hotkey": "control+shift+k", "interval": 0.5}}"#).autoclick
        XCTAssertEqual(c.hotkey, "control+shift+k")
        XCTAssertEqual(c.interval, 0.5)
        let bad = try decode(#"{"autoclick": {"hotkey": 3, "interval": "fast"}, "maxResults": 9}"#)
        XCTAssertEqual(bad.autoclick, Config.AutoClick(), "wrong types fall back to the defaults")
        XCTAssertEqual(bad.maxResults, 9)
        XCTAssertEqual(try decode(#"{"autoclick": "on"}"#).autoclick, Config.AutoClick())
        XCTAssertEqual(try decode(#"{"autoclick": {"hotkey": ""}}"#).autoclick.hotkey, "", "empty turns the hotkey off")
    }

    func testRoundTrip() throws {
        var c = Config()
        c.autoclick.interval = 0.1
        c.autoclick.hotkey = ""
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.autoclick, c.autoclick)
    }

    func testIntervalClamp() {
        XCTAssertEqual(AutoClickPlan.clamp(0), 0.01)
        XCTAssertEqual(AutoClickPlan.clamp(-5), 0.01)
        XCTAssertEqual(AutoClickPlan.clamp(0.001), 0.01)
        XCTAssertEqual(AutoClickPlan.clamp(0.02), 0.02)
        XCTAssertEqual(AutoClickPlan.clamp(1000), 60)
        XCTAssertEqual(AutoClickPlan.clamp(.nan), 0.02)
        XCTAssertEqual(AutoClickPlan.clamp(.infinity), 0.02)
        var c = Config.AutoClick()
        c.interval = 0.0001
        XCTAssertEqual(c.effectiveInterval, 0.01)
    }

    func testRateAndHotkeyLabels() {
        XCTAssertEqual(AutoClickPlan.rate(0.02), "50/s")
        XCTAssertEqual(AutoClickPlan.rate(0.01), "100/s")
        XCTAssertEqual(AutoClickPlan.rate(0.001), "100/s")
        XCTAssertEqual(AutoClickPlan.rate(1), "1/s")
        XCTAssertEqual(AutoClickPlan.rate(2), "0.5/s")
        XCTAssertEqual(AutoClickPlan.rate(3), "0.33/s")
        XCTAssertEqual(AutoClickPlan.hotkeyLabel("control+option+command+c"), "⌃⌥⌘C")
        XCTAssertEqual(AutoClickPlan.hotkeyLabel("command+shift+f5"), "⇧⌘F5")
        XCTAssertEqual(AutoClickPlan.hotkeyLabel("nonsense"), "nonsense")
    }

    func testToggleStartsAndStops() {
        var s = AutoClickState()
        XCTAssertEqual(s.handle(.toggle, trusted: true), .start)
        XCTAssertTrue(s.isOn)
        XCTAssertEqual(s.handle(.toggle, trusted: true), .stop(reason: "hotkey"))
        XCTAssertFalse(s.isOn)
    }

    func testNoStartWithoutAccessibility() {
        var s = AutoClickState()
        XCTAssertEqual(s.handle(.toggle, trusted: false), .needAccess)
        XCTAssertEqual(s.handle(.start, trusted: false), .needAccess)
        XCTAssertFalse(s.isOn)
    }

    func testEveryStopPath() {
        let stops: [(AutoClickState.Event, String)] = [
            (.stop, "command"), (.escape, "escape"), (.sleep, "sleep"), (.screenLock, "screen lock"), (.quit, "quit"),
        ]
        for (event, reason) in stops {
            var s = AutoClickState()
            XCTAssertEqual(s.handle(.start, trusted: true), .start)
            XCTAssertEqual(s.handle(event, trusted: true), .stop(reason: reason))
            XCTAssertFalse(s.isOn)
            XCTAssertEqual(s.handle(event, trusted: true), .none, "a stop while off does nothing")
        }
    }

    func testStartWhileOnDoesNothing() {
        var s = AutoClickState()
        _ = s.handle(.start, trusted: true)
        XCTAssertEqual(s.handle(.start, trusted: true), .none)
        XCTAssertTrue(s.isOn)
    }
}
