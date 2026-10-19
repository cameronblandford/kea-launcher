import XCTest
@testable import LauncherCore

final class HotKeyTests: XCTestCase {
    func testParsesOptionSpace() throws {
        let hk = try HotKeySpec.parse("option+space")
        XCTAssertEqual(hk.modifiers, [.option])
        XCTAssertEqual(hk.key, .space)
    }

    func testParsesMultipleModifiersAndLetter() throws {
        let hk = try HotKeySpec.parse("command+shift+k")
        XCTAssertEqual(hk.modifiers, [.command, .shift])
        XCTAssertEqual(hk.key, .letter("k"))
    }

    func testRejectsNoModifier() {
        XCTAssertThrowsError(try HotKeySpec.parse("space"))
    }

    func testRejectsUnknownKey() {
        XCTAssertThrowsError(try HotKeySpec.parse("option+banana"))
    }
}
