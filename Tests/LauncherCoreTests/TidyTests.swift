import XCTest
@testable import LauncherCore

final class TidyTests: XCTestCase {
    func testSize() {
        XCTAssertEqual(Tidy.size(38_400_000_000), "38 GB")
        XCTAssertEqual(Tidy.size(4_200_000_000), "4.2 GB")
        XCTAssertEqual(Tidy.size(512_000_000), "512 MB")
        XCTAssertEqual(Tidy.size(0), "0 KB")
    }

    func testDeviceSupportKeepsNewestPerFamily() {
        let names = ["iPhone16,1 26.0 (23A1)", "iPhone16,1 27.0 (24A5424a)", "iPhone16,1 25.4 (22E1)", "iPhone16,1 26.2 (23C1)",
                     "17.5 (21F79)", "18.0 (22A1)", "16.4 (20E1)"]
        XCTAssertEqual(Tidy.staleDeviceSupport(names),
                       ["16.4 (20E1)", "iPhone16,1 25.4 (22E1)", "iPhone16,1 26.0 (23A1)"])
        XCTAssertEqual(Tidy.staleDeviceSupport(["iPhone16,1 27.0 (24A5424a)"]), [])
    }

    func testVersionOrderIsNumeric() {
        XCTAssertEqual(Tidy.staleDeviceSupport(["9.3 (a)", "10.0 (b)", "11.1 (c)"], keep: 1), ["10.0 (b)", "9.3 (a)"])
    }

    func testStale() {
        let now = Date()
        XCTAssertTrue(Tidy.isStale(lastActivity: now.addingTimeInterval(-61 * 86400), now: now))
        XCTAssertFalse(Tidy.isStale(lastActivity: now.addingTimeInterval(-59 * 86400), now: now))
    }

    func testStoreDirFromBothFormats() {
        XCTAssertEqual(Tidy.pnpmStoreDir(fromModulesYaml: "layoutVersion: 5\nstoreDir: /Users/me/Library/pnpm/store/v3\nvirtualStoreDir: .pnpm\n"),
                       "/Users/me/Library/pnpm/store/v3")
        XCTAssertEqual(Tidy.pnpmStoreDir(fromModulesYaml: "{\n  \"hoistedDependencies\": {},\n  \"storeDir\": \"/Users/me/Library/pnpm/store/v11\",\n  \"x\": 1\n}"),
                       "/Users/me/Library/pnpm/store/v11")
        XCTAssertNil(Tidy.pnpmStoreDir(fromModulesYaml: "\"@types/store@2.0.2\": {}"))
    }

    func testUnusedStoresKeepAnythingAnActiveProjectUses() {
        let now = Date()
        let installs = [
            Tidy.PnpmInstall(store: "/s/v11", lastActivity: now),                                  // active
            Tidy.PnpmInstall(store: "/s/v3", lastActivity: now.addingTimeInterval(-19 * 86400)),   // active
            Tidy.PnpmInstall(store: "/old/v10", lastActivity: now.addingTimeInterval(-514 * 86400)),
            Tidy.PnpmInstall(store: "/s/v3/", lastActivity: now.addingTimeInterval(-500 * 86400)), // old, same store as an active one
        ]
        XCTAssertEqual(Tidy.unusedPnpmStores(["/s/v11", "/s/v3", "/s/v10", "/old/v10"], installs: installs, now: now),
                       ["/s/v10", "/old/v10"])
    }
}
