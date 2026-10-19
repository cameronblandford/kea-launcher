import XCTest
@testable import LauncherCore

final class CalculatorTests: XCTestCase {
    func eval(_ s: String) -> Double? { Calculator.evaluate(s) }

    func testBasicArithmeticAndPrecedence() {
        XCTAssertEqual(eval("2+3*4"), 14)
        XCTAssertEqual(eval("(2+3)*4"), 20)
        XCTAssertEqual(eval("10/4"), 2.5)
        XCTAssertEqual(eval("2^10"), 1024)
        XCTAssertEqual(eval("2^3^2"), 512) // right associative
        XCTAssertEqual(eval("-3+5"), 2)
        XCTAssertEqual(eval("2*-3"), -6)
    }

    func testFunctionsAndConstants() {
        XCTAssertEqual(eval("sqrt(16)"), 4)
        XCTAssertEqual(eval("abs(-2.5)"), 2.5)
        XCTAssertEqual(eval("round(2.6)"), 3)
        XCTAssertEqual(eval("pi*2")!, 2 * Double.pi, accuracy: 1e-9)
        XCTAssertEqual(eval("ln(e)")!, 1, accuracy: 1e-9)
        XCTAssertEqual(eval("log(1000)")!, 3, accuracy: 1e-9)
    }

    func testPercentAndSpaces() {
        XCTAssertEqual(eval("15% * 80"), 12)
        XCTAssertEqual(eval(" 1 + 1 "), 2)
        XCTAssertEqual(eval("1,000 + 1"), 1001)
    }

    func testPlainNumbersAndWordsAreNotExpressions() {
        XCTAssertNil(eval("2024"))
        XCTAssertNil(eval("safari"))
        XCTAssertNil(eval("3d"))
        XCTAssertNil(eval(""))
    }

    func testMalformedReturnsNil() {
        XCTAssertNil(eval("2+"))
        XCTAssertNil(eval("(2+3"))
        XCTAssertNil(eval("1/0"))
    }

    func testFormatting() {
        XCTAssertEqual(Calculator.format(14), "14")
        XCTAssertEqual(Calculator.format(2.5), "2.5")
        XCTAssertEqual(Calculator.format(1.0 / 3.0), "0.3333333333")
        XCTAssertEqual(Calculator.format(1e20), "100000000000000000000")
        XCTAssertEqual(Calculator.format(-0.0), "0")
    }
}
