import XCTest
@testable import LauncherCore

final class FrecencyTests: XCTestCase {
    func testUnknownIdHasMultiplierOne() {
        let f = Frecency()
        XCTAssertEqual(f.multiplier(for: "x", now: 1000), 1.0, accuracy: 0.0001)
    }

    func testRecordIncreasesMultiplier() {
        var f = Frecency()
        f.record("x", now: 1000)
        XCTAssertGreaterThan(f.multiplier(for: "x", now: 1000), 1.0)
        let once = f.multiplier(for: "x", now: 1000)
        f.record("x", now: 1000)
        XCTAssertGreaterThan(f.multiplier(for: "x", now: 1000), once)
    }

    func testRecencyBonusDecays() {
        var f = Frecency()
        f.record("x", now: 1000)
        let fresh = f.multiplier(for: "x", now: 1000)
        let dayOld = f.multiplier(for: "x", now: 1000 + 3600 * 12)
        let weekOld = f.multiplier(for: "x", now: 1000 + 86400 * 7)
        XCTAssertGreaterThan(fresh, dayOld)
        XCTAssertGreaterThan(dayOld, weekOld)
    }

    func testRoundTripsThroughJSON() throws {
        var f = Frecency()
        f.record("a", now: 5)
        f.record("a", now: 6)
        let data = try f.encoded()
        let back = try Frecency(data: data)
        XCTAssertEqual(back.multiplier(for: "a", now: 6), f.multiplier(for: "a", now: 6), accuracy: 0.0001)
    }
}
