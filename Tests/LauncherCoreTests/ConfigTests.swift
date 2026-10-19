import XCTest
@testable import LauncherCore

final class ConfigTests: XCTestCase {
    func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    func testEmptyConfigGetsDefaults() throws {
        let c = try decode("{}")
        XCTAssertEqual(c, Config())
        XCTAssertEqual(c.zones.keys["right"], "command+shift+right")
    }

    func testWrongTypeOnlyResetsThatKey() throws {
        let c = try decode(#"{"maxResults": "12", "hotkey": "command+space", "zones": {"gap": "wide", "focusWidth": 0.5}}"#)
        XCTAssertEqual(c.maxResults, 12, "a wrong type falls back to the default")
        XCTAssertEqual(c.hotkey, "command+space", "other keys still load")
        XCTAssertEqual(c.zones.gap, 8)
        XCTAssertEqual(c.zones.focusWidth, 0.5)
    }

    func testDisabledCommands() throws {
        XCTAssertEqual(try decode("{}").commands.disabled, [])
        XCTAssertEqual(try decode(#"{"commands": {"disabled": ["weather", "2048"]}}"#).commands.disabled, ["weather", "2048"])
        XCTAssertEqual(try decode(#"{"commands": {"disabled": "weather"}}"#).commands.disabled, [], "a wrong type falls back to nothing disabled")
    }

    /// `encode(to:)` is written by hand: a key that is left out there is lost at the next save in Settings.
    func testEncodeWritesEveryKey() throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as? [String: Any]
        let written = Set(try XCTUnwrap(object).keys)
        XCTAssertEqual(Set(Config.CodingKeys.allCases.map(\.rawValue)).subtracting(written), [])
    }

    func testEncodeRoundTrip() throws {
        var c = Config()
        c.hotkey = "command+space"
        c.zones.gap = 12
        c.commands.disabled = ["weather"]
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c)), c)
    }
}
