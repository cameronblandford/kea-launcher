import XCTest
@testable import LauncherCore

final class TerminalTests: XCTestCase {
    func testQuoteEscapesQuotesAndBackslashes() {
        XCTAssertEqual(TerminalLaunch.quote(#"echo "a\b""#), #""echo \"a\\b\"""#)
    }

    func testGhosttyTypesTheCommandIntoTheShell() throws {
        let s = try XCTUnwrap(TerminalLaunch.script(app: TerminalLaunch.ghostty, command: " ls -la ", directory: "/Users/me"))
        XCTAssertTrue(s.contains(#"set initial working directory of cfg to "/Users/me""#))
        XCTAssertTrue(s.contains(#"set initial input of cfg to "ls -la" & return"#))
        XCTAssertTrue(s.contains("new window with configuration cfg"))
    }

    func testGhosttyWithoutCommandOpensAWindowOnly() throws {
        let s = try XCTUnwrap(TerminalLaunch.script(app: TerminalLaunch.ghostty, command: "", directory: "/Users/me"))
        XCTAssertFalse(s.contains("initial input"))
        XCTAssertTrue(s.contains("new window with configuration cfg"))
    }

    func testAppleTerminal() throws {
        let s = try XCTUnwrap(TerminalLaunch.script(app: TerminalLaunch.appleTerminal, command: "top", directory: "/Users/o'neil"))
        XCTAssertTrue(s.contains(#"do script "cd '/Users/o'\\''neil' && top""#))
    }

    func testUnknownTerminal() {
        XCTAssertNil(TerminalLaunch.script(app: "com.example.term", command: "ls", directory: "/"))
    }

    func testConfigDefaultsAndOldFiles() throws {
        XCTAssertEqual(Config().terminal.keyword, "t")
        XCTAssertEqual(Config().terminal.app, TerminalLaunch.ghostty)
        let cfg = try JSONDecoder().decode(Config.self, from: Data(#"{"terminal": {"app": "com.apple.Terminal"}}"#.utf8))
        XCTAssertEqual(cfg.terminal.app, TerminalLaunch.appleTerminal)
        XCTAssertEqual(cfg.terminal.keyword, "t")
    }
}
