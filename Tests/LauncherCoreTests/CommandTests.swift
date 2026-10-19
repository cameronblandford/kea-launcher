import XCTest
@testable import LauncherCore

final class CommandTests: XCTestCase {
    func testDecodesManifestWithDefaults() throws {
        let json = #"{"title":"Kill Port","keyword":"kp"}"#.data(using: .utf8)!
        let m = try CommandManifest.decode(json)
        XCTAssertEqual(m.title, "Kill Port")
        XCTAssertEqual(m.keyword, "kp")
        XCTAssertEqual(m.mode, .action)
        XCTAssertNil(m.subtitle)
    }

    func testDecodesListMode() throws {
        let json = #"{"title":"Projects","keyword":"p","mode":"list","icon":"sf:folder"}"#.data(using: .utf8)!
        let m = try CommandManifest.decode(json)
        XCTAssertEqual(m.mode, .list)
        XCTAssertEqual(m.icon, "sf:folder")
    }

    func testDecodesScriptOutput() throws {
        let json = """
        {"items":[
          {"title":"density","subtitle":"~/Projects/density","action":{"type":"open","target":"/Users/me/Projects/density"}},
          {"title":"no action"},
          {"title":"copy me","action":{"type":"copy","target":"hello"}}
        ]}
        """.data(using: .utf8)!
        let out = try ScriptOutput.decode(json)
        XCTAssertEqual(out.items.count, 3)
        XCTAssertEqual(out.items[0].action, .open("/Users/me/Projects/density"))
        XCTAssertNil(out.items[1].action)
        XCTAssertEqual(out.items[2].action, .copy("hello"))
    }

    func testUnknownActionTypeIsIgnoredNotFatal() throws {
        let json = #"{"items":[{"title":"x","action":{"type":"teleport","target":"mars"}}]}"#.data(using: .utf8)!
        let out = try ScriptOutput.decode(json)
        XCTAssertNil(out.items[0].action)
    }
}
