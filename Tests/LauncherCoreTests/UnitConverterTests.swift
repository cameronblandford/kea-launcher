import XCTest
@testable import LauncherCore

final class UnitConverterTests: XCTestCase {
    let rates = CurrencyRates(base: "USD", rates: ["EUR": 0.9, "GBP": 0.8, "USD": 1.0], date: "2026-09-15")

    func conv(_ s: String) -> Conversion? { UnitConverter.convert(s, rates: rates) }

    func testLength() {
        let c = conv("10 mi in km")!
        XCTAssertEqual(c.value, 16.0934, accuracy: 0.001)
        XCTAssertEqual(c.unit, "km")
    }

    func testTemperatureAndNoSpace() {
        XCTAssertEqual(conv("72f to c")!.value, 22.222, accuracy: 0.01)
        XCTAssertEqual(conv("100 c in f")!.value, 212, accuracy: 0.001)
    }

    func testInchIsNotConfusedWithSeparator() {
        XCTAssertEqual(conv("10 in in cm")!.value, 25.4, accuracy: 0.001)
    }

    func testDataAndDuration() {
        XCTAssertEqual(conv("1 gb in mb")!.value, 1000, accuracy: 0.001)
        XCTAssertEqual(conv("1 gib in mib")!.value, 1024, accuracy: 0.001)
        XCTAssertEqual(conv("2 days in hours")!.value, 48, accuracy: 0.001)
        XCTAssertEqual(conv("90 min in h")!.value, 1.5, accuracy: 0.001)
    }

    func testMassVolumeSpeed() {
        XCTAssertEqual(conv("1 lb in kg")!.value, 0.4536, accuracy: 0.001)
        XCTAssertEqual(conv("1 gal in l")!.value, 3.785, accuracy: 0.01)
        XCTAssertEqual(conv("60 mph in kph")!.value, 96.56, accuracy: 0.01)
    }

    func testCurrency() {
        let c = conv("100 usd in eur")!
        XCTAssertEqual(c.value, 90, accuracy: 0.001)
        XCTAssertEqual(c.unit, "EUR")
        XCTAssertEqual(conv("90 eur to gbp")!.value, 80, accuracy: 0.001)
    }

    func testCurrencyWithoutRatesIsNil() {
        XCTAssertNil(UnitConverter.convert("100 usd in eur", rates: nil))
    }

    func testRejectsMismatchedOrUnknown() {
        XCTAssertNil(conv("10 mi in kg"))
        XCTAssertNil(conv("abc in def"))
        XCTAssertNil(conv("10 in"))
        XCTAssertNil(conv("safari"))
        XCTAssertNil(conv("1,000 usd in xyz"))
    }

    func testThousandsSeparator() {
        XCTAssertEqual(conv("1,000 m in km")!.value, 1, accuracy: 0.001)
    }

    func testRatesRoundTrip() throws {
        let data = try rates.encoded()
        let back = try CurrencyRates(data: data)
        XCTAssertEqual(back.rates["EUR"], 0.9)
        XCTAssertEqual(back.date, "2026-09-15")
    }
}
