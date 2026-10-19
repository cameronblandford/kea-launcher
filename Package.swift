// swift-tools-version:5.9
import Foundation
import PackageDescription

// Kea's own build has more features than the public repository. Their sources are in a
// folder named `Personal` inside a target's folder. A target that has the folder builds
// it and leaves out `PersonalStub.swift`, which gives empty versions of the same seam.
func hasPersonal(_ target: String) -> Bool {
    FileManager.default.fileExists(atPath: "\(Context.packageDirectory)/\(target)/Personal")
}
func stubUnlessPersonal(_ target: String) -> [String] { hasPersonal(target) ? ["PersonalStub.swift"] : [] }
// SwiftPM keeps the result of this file and does not see a `Personal` folder come or go.
// After you add or remove one, build once with `--manifest-cache none`.

let package = Package(
    name: "Launcher",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Launcher", targets: ["Launcher"]),
        .library(name: "LauncherCore", targets: ["LauncherCore"]),
    ],
    targets: [
        .target(name: "LauncherCore", exclude: stubUnlessPersonal("Sources/LauncherCore")),
        .executableTarget(
            name: "Launcher",
            dependencies: ["LauncherCore"],
            exclude: stubUnlessPersonal("Sources/Launcher"),
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("AppKit"), .linkedFramework("Quartz"), .linkedFramework("ServiceManagement"), .linkedFramework("EventKit"), .linkedFramework("CoreLocation"), .linkedFramework("CoreAudio"), .linkedFramework("IOBluetooth")]
        ),
        .testTarget(name: "LauncherCoreTests", dependencies: ["LauncherCore"]),
    ]
    // The root helper is all personal: without its folder there is no such target.
    + (hasPersonal("Sources/KeaHelper") ? [.executableTarget(name: "KeaHelper", dependencies: ["LauncherCore"])] : []),
    swiftLanguageVersions: [.v5]
)
