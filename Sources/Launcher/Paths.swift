import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let root = home.appendingPathComponent(".launcher", isDirectory: true)
    /// `KEA_CONFIG=/path/to/config.json` points a check at another config file.
    static let config = ProcessInfo.processInfo.environment["KEA_CONFIG"].map { URL(fileURLWithPath: $0) }
        ?? root.appendingPathComponent("config.json")
    static let frecency = root.appendingPathComponent("frecency.json")
    static let commands = root.appendingPathComponent("commands", isDirectory: true)

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func ensureRoot() {
        try? FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
    }
}
