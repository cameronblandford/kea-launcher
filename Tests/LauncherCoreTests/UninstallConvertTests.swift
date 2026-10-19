import XCTest
@testable import LauncherCore

final class UninstallTests: XCTestCase {
    func testBundleIdAndNameMatch() {
        func belongs(_ item: String) -> Bool { Uninstall.belongs(item, appName: "Stability Matrix", bundleId: "com.lykos.StabilityMatrix") }
        XCTAssertTrue(belongs("StabilityMatrix"))
        XCTAssertTrue(belongs("Stability Matrix"))
        XCTAssertTrue(belongs("com.lykos.stabilitymatrix"))
        XCTAssertTrue(belongs("com.lykos.StabilityMatrix.plist"))
        XCTAssertTrue(belongs("com.lykos.StabilityMatrix.savedState"))
        XCTAssertTrue(belongs("com.lykos.StabilityMatrix.helper"))
        XCTAssertFalse(belongs("com.lykos.StabilityMatrixPro"), "another app whose id only starts the same")
        XCTAssertFalse(belongs("com.lykos"))
        XCTAssertFalse(belongs("Stability"))
        XCTAssertFalse(belongs("Stability Matrix Backup"))
    }

    func testShortNamesMatchNothing() {
        XCTAssertFalse(Uninstall.belongs("Go", appName: "Go", bundleId: nil))
        XCTAssertFalse(Uninstall.belongs("x", appName: "Xcode", bundleId: "x"))
        XCTAssertTrue(Uninstall.belongs("Ollama", appName: "Ollama", bundleId: nil))
        XCTAssertTrue(Uninstall.belongs("com.electron.ollama.plist", appName: "Ollama", bundleId: "com.electron.ollama"))
    }

    func testHomeFolder() {
        XCTAssertEqual(Uninstall.homeFolder(appName: "Ollama"), ".ollama")
        XCTAssertEqual(Uninstall.homeFolder(appName: "Stability Matrix"), ".stabilitymatrix")
        XCTAssertNil(Uninstall.homeFolder(appName: "Git"))
        XCTAssertNil(Uninstall.homeFolder(appName: "../etc"))
    }

    func testProtectedApps() {
        XCTAssertTrue(Uninstall.isProtected(path: "/System/Applications/Mail.app", bundleId: "com.apple.mail"))
        XCTAssertTrue(Uninstall.isProtected(path: "/Applications/Safari.app", bundleId: "com.apple.Safari"))
        XCTAssertTrue(Uninstall.isProtected(path: "/Applications/Kea.app", bundleId: "directory.kea.launcher"))
        XCTAssertFalse(Uninstall.isProtected(path: "/Applications/Ollama.app", bundleId: "com.electron.ollama"))
        XCTAssertFalse(Uninstall.isProtected(path: "/Applications/Thing.app", bundleId: nil))
    }
}

final class ConvertTests: XCTestCase {
    func testKindsAndTargets() {
        XCTAssertEqual(Convert.kind(ofPath: "/a/Photo.HEIC"), .image)
        XCTAssertEqual(Convert.kind(ofPath: "/a/clip.mov"), .video)
        XCTAssertNil(Convert.kind(ofPath: "/a/notes.txt"))
        XCTAssertEqual(Convert.target(from: "JPG"), .jpeg)
        XCTAssertEqual(Convert.target(from: " gif "), .gif)
        XCTAssertEqual(Convert.target(from: "1600"), .resize(1600))
        XCTAssertEqual(Convert.target(from: "800px"), .resize(800))
        XCTAssertNil(Convert.target(from: "3"))
        XCTAssertNil(Convert.target(from: "docx"))
    }

    func testOffersOnlyWhatChangesSomething() {
        XCTAssertEqual(Convert.targets(forPaths: ["/a/x.heic"]), [.jpeg, .png, .resize(1600)])
        XCTAssertEqual(Convert.targets(forPaths: ["/a/x.png"]), [.jpeg, .resize(1600)])
        XCTAssertEqual(Convert.targets(forPaths: ["/a/x.jpg", "/a/y.jpeg"]), [.png, .resize(1600)])
        XCTAssertEqual(Convert.targets(forPaths: ["/a/x.mov"]), [.mp4, .gif])
        XCTAssertEqual(Convert.targets(forPaths: ["/a/x.mp4"]), [.gif])
        XCTAssertEqual(Convert.targets(forPaths: ["/a/x.png", "/a/y.mov"]), [.jpeg, .png, .resize(1600), .mp4, .gif])
        XCTAssertTrue(Convert.targets(forPaths: ["/a/notes.txt"]).isEmpty)
    }

    func testApplicableFiles() {
        let files = ["/a/x.png", "/a/y.jpg", "/a/z.mov", "/a/n.txt"]
        XCTAssertEqual(Convert.applicable(files, to: .jpeg), ["/a/x.png"])
        XCTAssertEqual(Convert.applicable(files, to: .resize(800)), ["/a/x.png", "/a/y.jpg"])
        XCTAssertEqual(Convert.applicable(files, to: .gif), ["/a/z.mov"])
    }

    func testOutputPath() {
        let taken: Set<String> = ["/a/photo.jpg", "/a/photo 2.jpg"]
        XCTAssertEqual(Convert.outputPath(for: "/a/photo.heic", target: .jpeg) { taken.contains($0) }, "/a/photo 3.jpg")
        XCTAssertEqual(Convert.outputPath(for: "/a/clip.v2.mov", target: .gif) { _ in false }, "/a/clip.v2.gif")
        XCTAssertEqual(Convert.outputPath(for: "/a/photo.png", target: .resize(1600)) { _ in false }, "/a/photo 1600px.png")
    }
}

final class TidyRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }

    func testUnusedRuntimesKeepTheNewestAndTheRecent() {
        let runtimes = [Tidy.SimulatorRuntime(id: "a", version: "26.4.1", bytes: 8, lastUsed: ago(200)),
                        Tidy.SimulatorRuntime(id: "b", version: "18.6", bytes: 8, lastUsed: ago(240)),
                        Tidy.SimulatorRuntime(id: "c", version: "18.3.1", bytes: 8, lastUsed: ago(10)),
                        Tidy.SimulatorRuntime(id: "d", version: "17.5", bytes: 8, lastUsed: nil)]
        XCTAssertEqual(Tidy.unusedRuntimes(runtimes, now: now).map(\.id), ["b", "d"])
        XCTAssertTrue(Tidy.unusedRuntimes([runtimes[1]], now: now).isEmpty, "the only runtime stays")
        XCTAssertTrue(Tidy.unusedRuntimes([], now: now).isEmpty)
        // 26.10 is newer than 26.4.
        let two = [Tidy.SimulatorRuntime(id: "x", version: "26.4", bytes: 8, lastUsed: nil), Tidy.SimulatorRuntime(id: "y", version: "26.10", bytes: 8, lastUsed: nil)]
        XCTAssertEqual(Tidy.unusedRuntimes(two, now: now).map(\.id), ["x"])
    }

    func testEjectableImages() {
        XCTAssertTrue(Tidy.isEjectable(imagePath: "/var/folders/x/T/DockerDesktopUpdates/Docker.dmg", mountPoints: ["/private/var/folders/x/T/com.docker.install/D"]))
        XCTAssertTrue(Tidy.isEjectable(imagePath: "/Users/me/Downloads/App.dmg", mountPoints: ["/Volumes/App"]))
        XCTAssertFalse(Tidy.isEjectable(imagePath: "/System/Library/AssetsV2/x/a.dmg", mountPoints: ["/Library/Developer/CoreSimulator/Volumes/iOS_1"]))
        XCTAssertFalse(Tidy.isEjectable(imagePath: "/Library/Developer/CoreSimulator/Cryptex/Images/b/Restore/a.dmg", mountPoints: ["/Library/Developer/CoreSimulator/Volumes/iOS_2"]))
        XCTAssertFalse(Tidy.isEjectable(imagePath: "/Users/me/a.dmg", mountPoints: []), "not mounted")
    }

    func testDisposableImages() {
        XCTAssertTrue(Tidy.isDisposableImage(path: "/var/folders/x/T/Docker.dmg", home: "/Users/me"))
        XCTAssertTrue(Tidy.isDisposableImage(path: "/Users/me/Downloads/App.dmg", home: "/Users/me"))
        XCTAssertFalse(Tidy.isDisposableImage(path: "/Users/me/Documents/Vault.dmg", home: "/Users/me"))
        XCTAssertFalse(Tidy.isDisposableImage(path: "/Users/me/Downloads/../Documents/Vault.dmg", home: "/Users/me"))
    }

    func testModelFiles() {
        XCTAssertTrue(Tidy.isModelFile(extension: "safetensors", bytes: 6_500_000_000))
        XCTAssertFalse(Tidy.isModelFile(extension: "safetensors", bytes: 20_000_000))
        XCTAssertFalse(Tidy.isModelFile(extension: "bin", bytes: 900_000_000))
        XCTAssertTrue(Tidy.isModelFile(extension: "bin", bytes: 4_000_000_000))
        XCTAssertFalse(Tidy.isModelFile(extension: "mp4", bytes: 9_000_000_000))
    }
}
