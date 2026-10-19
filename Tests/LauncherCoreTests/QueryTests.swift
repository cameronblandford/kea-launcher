import XCTest
@testable import LauncherCore

final class QueryTests: XCTestCase {
    let keywords: Set<String> = ["p", "kp"]

    func testPlainQuery() {
        let q = Query.parse("safari", listKeywords: keywords)
        XCTAssertEqual(q, .search("safari"))
    }

    func testBareKeywordOpensCommand() {
        XCTAssertEqual(Query.parse("p", listKeywords: keywords), .command(keyword: "p", argument: ""))
        XCTAssertEqual(Query.parse("pa", listKeywords: keywords), .search("pa"))
    }

    func testKeywordWithSpaceRoutesToCommand() {
        XCTAssertEqual(Query.parse("p dens", listKeywords: keywords), .command(keyword: "p", argument: "dens"))
        XCTAssertEqual(Query.parse("p ", listKeywords: keywords), .command(keyword: "p", argument: ""))
    }

    func testWhitespaceIsTrimmedForSearch() {
        XCTAssertEqual(Query.parse("  notes ", listKeywords: keywords), .search("notes"))
    }
}
