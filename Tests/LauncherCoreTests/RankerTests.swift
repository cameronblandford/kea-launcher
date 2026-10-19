import XCTest
@testable import LauncherCore

final class RankerTests: XCTestCase {
    func testFrecencyReordersTies() {
        var f = Frecency()
        f.record("b", now: 100)
        let items = [
            Rankable(id: "a", text: "Notes"),
            Rankable(id: "b", text: "Notes"),
        ]
        let ranked = Ranker.rank(items, query: "notes", frecency: f, now: 100)
        XCTAssertEqual(ranked.map(\.id), ["b", "a"])
    }

    func testNonMatchesDropped() {
        let items = [Rankable(id: "a", text: "Safari"), Rankable(id: "b", text: "Mail")]
        let ranked = Ranker.rank(items, query: "saf", frecency: Frecency(), now: 0)
        XCTAssertEqual(ranked.map(\.id), ["a"])
    }
}
