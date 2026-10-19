import XCTest
@testable import LauncherCore

final class FancyTextTests: XCTestCase {
    let tsv = """
    😀\tgrinning face\tcheerful face grin happy smile
    ❤️\tred heart\tlove heart
    ❤️‍🔥\theart on fire\tburn love lust heart
    🎉\tparty popper\tcelebrate party tada
    🥳\tpartying face\tbirthday celebrate party hat
    ❄️\tsnowflake\tcold snow winter
    """

    func testEmojiSearchPrefersNameAndShortNames() {
        let idx = EmojiIndex(tsv: tsv)
        XCTAssertEqual(idx.all.count, 6)
        XCTAssertEqual(idx.search("heart", frecency: Frecency()).map(\.char), ["❤️", "❤️‍🔥"])
        XCTAssertEqual(idx.search("party", frecency: Frecency()).first?.char, "🎉")
        XCTAssertEqual(idx.search("snow", frecency: Frecency()).map(\.char), ["❄️"])
        XCTAssertEqual(idx.search("happy grin", frecency: Frecency()).map(\.char), ["😀"])
        XCTAssertTrue(idx.search("zzz", frecency: Frecency()).isEmpty)
    }

    func testEmojiFrecencyReordersAndLeadsEmptyQuery() {
        let idx = EmojiIndex(tsv: tsv)
        var f = Frecency()
        for _ in 0..<5 { f.record("emoji:🥳") }
        XCTAssertEqual(idx.search("party", frecency: f).first?.char, "🥳")
        XCTAssertEqual(idx.search("", frecency: f).first?.char, "🥳")
        XCTAssertEqual(idx.search("", frecency: f).count, 6)
    }

    func testZalgoKeepsLettersAndIsDeterministic() {
        let a = Zalgo.generate("hi there", level: .medium, seed: 3)
        XCTAssertEqual(a, Zalgo.generate("hi there", level: .medium, seed: 3))
        let base = String(String.UnicodeScalarView(a.unicodeScalars.filter { !$0.properties.isDiacritic && $0.properties.generalCategory != .nonspacingMark && $0.properties.generalCategory != .enclosingMark }))
        XCTAssertEqual(base, "hi there")
        XCTAssertGreaterThan(Zalgo.generate("hi", level: .max).unicodeScalars.count,
                             Zalgo.generate("hi", level: .mild).unicodeScalars.count)
        // Still two visible letters.
        XCTAssertEqual(Zalgo.generate("hi", level: .max).count, 2)
    }
}
