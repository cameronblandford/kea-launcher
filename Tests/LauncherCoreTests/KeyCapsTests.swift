import XCTest
@testable import LauncherCore

final class KeyCapsTests: XCTestCase {
    func testMenu() {
        XCTAssertEqual(KeyCaps.menu(char: "n", modifiers: 0), ["⌘", "N"])
        XCTAssertEqual(KeyCaps.menu(char: "N", modifiers: 1), ["⇧", "⌘", "N"])
        XCTAssertEqual(KeyCaps.menu(char: "f", modifiers: 4), ["⌃", "⌘", "F"])
        XCTAssertEqual(KeyCaps.menu(char: "5", modifiers: 7), ["⌃", "⌥", "⇧", "⌘", "5"])
        XCTAssertEqual(KeyCaps.menu(char: "F5", modifiers: 8), ["F5"])   // bit 8: no Command
        XCTAssertEqual(KeyCaps.menu(char: ",", modifiers: 0), ["⌘", ","])
    }

    func testNamedKeys() {
        XCTAssertEqual(KeyCaps.menu(char: " ", modifiers: 4), ["⌃", "⌘", "Space"])
        XCTAssertEqual(KeyCaps.menu(char: "\r", modifiers: 0), ["⌘", "↩"])
        XCTAssertEqual(KeyCaps.menu(char: "\u{1B}", modifiers: 8), ["esc"])
    }

    func testNoShortcut() {
        XCTAssertEqual(KeyCaps.menu(char: "", modifiers: 0), [])
    }
}
