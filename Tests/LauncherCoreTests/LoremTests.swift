import XCTest
@testable import LauncherCore

final class LoremTests: XCTestCase {
    func testPhraseIsAFewWordsInSentenceCase() {
        let p = Lorem.generate(.phrase, seed: 1)
        let words = p.split(separator: " ")
        XCTAssertTrue((4...6).contains(words.count))
        XCTAssertFalse(p.hasSuffix("."))
        XCTAssertTrue(p.first!.isUppercase)
        XCTAssertEqual(String(p.dropFirst()), String(p.dropFirst()).lowercased())
    }

    func testSentenceIsTheClassicOpening() {
        XCTAssertEqual(Lorem.generate(.sentence, seed: 1), "Lorem ipsum dolor sit amet, consectetur adipiscing elit.")
    }

    func testParagraphStartsClassicAndHasSeveralSentences() {
        let p = Lorem.generate(.paragraph, seed: 7)
        XCTAssertTrue(p.hasPrefix("Lorem ipsum dolor sit amet"))
        XCTAssertFalse(p.contains("\n"))
        let sentences = p.split(separator: ".").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertTrue((4...6).contains(sentences.count), "\(sentences.count)")
    }

    func testFiveParagraphsAreSeparatedByBlankLines() {
        let p = Lorem.generate(.fiveParagraphs, seed: 3)
        let paras = p.components(separatedBy: "\n\n")
        XCTAssertEqual(paras.count, 5)
        XCTAssertTrue(paras[0].hasPrefix("Lorem ipsum"))
        XCTAssertFalse(paras[1].hasPrefix("Lorem ipsum dolor sit amet, consectetur"))
    }

    func testSeedIsDeterministic() {
        XCTAssertEqual(Lorem.generate(.paragraph, seed: 42), Lorem.generate(.paragraph, seed: 42))
        XCTAssertNotEqual(Lorem.generate(.paragraph, seed: 42), Lorem.generate(.paragraph, seed: 43))
    }

    func testParseRequest() {
        XCTAssertEqual(Lorem.parseRequest("3"), .init(paragraphs: 3, markdown: false))
        XCTAssertEqual(Lorem.parseRequest("3 md"), .init(paragraphs: 3, markdown: true))
        XCTAssertEqual(Lorem.parseRequest("md 12"), .init(paragraphs: 12, markdown: true))
        XCTAssertEqual(Lorem.parseRequest("markdown"), .init(paragraphs: 5, markdown: true))
        XCTAssertEqual(Lorem.parseRequest("500"), .init(paragraphs: 100, markdown: false))
        XCTAssertEqual(Lorem.parseRequest("0"), .init(paragraphs: 1, markdown: false))
        XCTAssertNil(Lorem.parseRequest("phrase"))
        XCTAssertNil(Lorem.parseRequest("3 4"))
        XCTAssertNil(Lorem.parseRequest(""))
    }

    func testParagraphCount() {
        let text = Lorem.paragraphs(7, seed: 3)
        XCTAssertEqual(text.components(separatedBy: "\n\n").count, 7)
        XCTAssertTrue(text.hasPrefix("Lorem ipsum dolor sit amet"))
        XCTAssertEqual(Lorem.paragraphs(1, seed: 3).components(separatedBy: "\n\n").count, 1)
    }

    func testMarkdownHasEveryKindOfBlock() {
        let md = Lorem.markdown(paragraphs: 6, seed: 5)
        XCTAssertTrue(md.hasPrefix("# "))
        for needle in ["\n\n## ", "\n\n### ", "![", "](https://picsum.photos/seed/", "\n- ", "\n> ", "\n1. ", "```js", "|---|---|---|", "**", "](https://example.com)"] {
            XCTAssertTrue(md.contains(needle), "missing \(needle)")
        }
        // Six prose paragraphs: blocks that start with a capital letter and are not markup.
        let prose = md.components(separatedBy: "\n\n").filter { b in
            guard let c = b.first else { return false }
            return c.isLetter && !b.hasPrefix("const")
        }
        XCTAssertEqual(prose.count, 6)
        XCTAssertEqual(Lorem.markdown(paragraphs: 6, seed: 5), md, "same seed, same text")
    }

    func testOneMarkdownParagraphStillShowsInlineStyles() {
        let md = Lorem.markdown(paragraphs: 1, seed: 2)
        XCTAssertTrue(md.contains("**") && md.contains("![") && md.hasPrefix("# "))
    }
}
