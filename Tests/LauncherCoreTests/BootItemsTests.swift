import XCTest
@testable import LauncherCore

final class BootItemsTests: XCTestCase {
    let sample = """
     Records for UID 501 : D61AC38E
    ========================

     Items:

     #1:
                     UUID: 12EB
                     Name: (null)
                     Type: developer (0x20)
              Disposition: [disabled, allowed, not notified] (0x2)
               Identifier: Unknown Developer
      Embedded Item Identifiers:
        #1: 16.org.nixos.darwin-store

     #2:
                     Name: postgres
                     Type: legacy agent (0x10008)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 8.homebrew.mxcl.postgresql@16
                      URL: file:///Users/me/Library/LaunchAgents/homebrew.mxcl.postgresql@16.plist
          Executable Path: /opt/homebrew/opt/postgresql@16/bin/postgres

     #3:
                     Name: Beeper Desktop
           Developer Name: Automattic, Inc.
                     Type: app (0x2)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 2.com.automattic.beeper.desktop
                      URL: file:///Applications/Beeper%20Desktop.app/

     #4:
                     Name: Arc
                     Type: app (0x2)
              Disposition: [disabled, allowed, notified] (0xa)
               Identifier: 2.company.thebrowser.Browser
                      URL: file:///Applications/Arc.app/

     #5:
                     Name: Spotlight
                     Type: legacy agent (0x10008)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 8.com.apple.Spotlight
    """

    func testParse() {
        let items = BootItems.parse(sample)
        XCTAssertEqual(items.map(\.name), ["postgres", "Beeper Desktop", "Arc"])
        XCTAssertEqual(items[0].kind, .agent)
        XCTAssertEqual(items[0].identifier, "homebrew.mxcl.postgresql@16")
        XCTAssertEqual(items[0].url, "/Users/me/Library/LaunchAgents/homebrew.mxcl.postgresql@16.plist")
        XCTAssertEqual(items[1].kind, .loginApp)
        XCTAssertEqual(items[1].url, "/Applications/Beeper Desktop.app")
        XCTAssertEqual(items[1].developer, "Automattic, Inc.")
        XCTAssertTrue(items[1].enabled)
        XCTAssertFalse(items[2].enabled)
        XCTAssertEqual(items[0].uid, 501)
    }
}
