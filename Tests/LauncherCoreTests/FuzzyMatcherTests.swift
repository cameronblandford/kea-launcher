import XCTest
@testable import LauncherCore

final class FuzzyMatcherTests: XCTestCase {
    func testEmptyQueryMatchesEverythingWithZeroScore() {
        XCTAssertEqual(FuzzyMatcher.score(query: "", candidate: "Safari"), 0)
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(FuzzyMatcher.score(query: "xyz", candidate: "Safari"))
    }

    func testCaseInsensitive() {
        XCTAssertNotNil(FuzzyMatcher.score(query: "SAF", candidate: "safari"))
    }

    func testPrefixBeatsScattered() {
        let prefix = FuzzyMatcher.score(query: "saf", candidate: "Safari")!
        let scattered = FuzzyMatcher.score(query: "saf", candidate: "System Analysis Framework")!
        XCTAssertGreaterThan(prefix, scattered)
    }

    func testInitialsMatchWell() {
        let initials = FuzzyMatcher.score(query: "vsc", candidate: "Visual Studio Code")!
        let weak = FuzzyMatcher.score(query: "vsc", candidate: "Divisor Scan")!
        XCTAssertGreaterThan(initials, weak)
    }

    func testWordPrefixNearlyMatchesPrefix() {
        let prefix = FuzzyMatcher.score(query: "chr", candidate: "chrome")!
        let word = FuzzyMatcher.score(query: "chr", candidate: "Google Chrome")!
        let scattered = FuzzyMatcher.score(query: "chr", candidate: "Search Results")!
        XCTAssertGreaterThan(prefix, word)
        XCTAssertGreaterThan(word, prefix * 0.8)
        XCTAssertGreaterThan(word, scattered * 2)
    }

    func testExactMatchIsHighest() {
        let exact = FuzzyMatcher.score(query: "notes", candidate: "Notes")!
        let partial = FuzzyMatcher.score(query: "notes", candidate: "Notes Archive")!
        XCTAssertGreaterThan(exact, partial)
    }
}
