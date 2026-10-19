import XCTest
@testable import LauncherCore

final class WebSearchTests: XCTestCase {
    func testBuildsURLWithEncodedQuery() {
        let url = WebSearch.url(template: "https://www.google.com/search?q={query}", query: "hello world & more")
        XCTAssertEqual(url?.absoluteString, "https://www.google.com/search?q=hello%20world%20%26%20more")
    }

    func testDefaultEnginesIncludeGoogle() {
        XCTAssertNotNil(Config().webSearches["g"])
    }
}
