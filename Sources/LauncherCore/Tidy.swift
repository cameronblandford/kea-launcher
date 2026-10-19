import Foundation

/// The rules behind `tidy`: what counts as stale, what to keep, and how sizes read.
/// The scanning and clearing live in the app (TidyCommand.swift).
public enum Tidy {
    /// "38 GB", "4.2 GB", "512 MB", "0 KB". Decimal units, like Finder.
    public static func size(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b >= 10e9 { return String(format: "%.0f GB", b / 1e9) }
        if b >= 1e9 { return String(format: "%.1f GB", b / 1e9) }
        if b >= 1e6 { return String(format: "%.0f MB", b / 1e6) }
        return String(format: "%.0f KB", b / 1e3)
    }

    /// iOS DeviceSupport folders to remove: all but the newest `keep` per device
    /// family. Folder names look like "iPhone16,1 27.0 (24A5424a)" or "17.5 (21F79)".
    public static func staleDeviceSupport(_ names: [String], keep: Int = 2) -> [String] {
        func version(_ name: String) -> [Int] {
            guard let v = name.split(separator: " ").first(where: { $0.first?.isNumber == true && $0.contains(".") }) else { return [] }
            return v.split(separator: ".").compactMap { Int($0) }
        }
        func family(_ name: String) -> String {
            let first = name.split(separator: " ").first.map(String.init) ?? ""
            return first.contains(",") ? first : ""
        }
        var out: [String] = []
        for (_, group) in Dictionary(grouping: names, by: family) {
            let sorted = group.sorted { version($0).lexicographicallyPrecedes(version($1)) }
            out += sorted.dropLast(keep)
        }
        return out.sorted()
    }

    /// A project's build folders are stale when nothing in it changed for `days`.
    public static func isStale(lastActivity: Date, now: Date = Date(), days: Double = 60) -> Bool {
        now.timeIntervalSince(lastActivity) > days * 86400
    }

    /// Folder names that hold rebuildable output inside a project.
    public static let buildFolders: Set<String> = ["node_modules", ".build", "target", "dist", ".next", "DerivedData"]

    /// The store a pnpm install uses, from its `node_modules/.modules.yaml`.
    /// pnpm 9 writes YAML (`storeDir: /path`); newer versions write JSON (`"storeDir": "/path"`).
    public static func pnpmStoreDir(fromModulesYaml text: String) -> String? {
        guard let r = text.range(of: #"(?m)^\s*"?storeDir"?\s*:\s*"?([^"\n,]+)"?"#, options: .regularExpression) else { return nil }
        let line = String(text[r])
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        return value.isEmpty ? nil : value
    }

    /// One pnpm install: its store, and when the project was last active.
    public struct PnpmInstall: Equatable {
        public var store: String
        public var lastActivity: Date
        public init(store: String, lastActivity: Date) { self.store = store; self.lastActivity = lastActivity }
    }

    /// Stores no project active in the last `days` uses. Those can go as a whole;
    /// a store any active project uses is kept whole.
    public static func unusedPnpmStores(_ stores: [String], installs: [PnpmInstall], now: Date = Date(), days: Double = 30) -> [String] {
        func norm(_ p: String) -> String { (p as NSString).standardizingPath.lowercased() }
        let active = Set(installs.filter { !isStale(lastActivity: $0.lastActivity, now: now, days: days) }.map { norm($0.store) })
        return stores.filter { !active.contains(norm($0)) }
    }

    /// One Xcode simulator runtime, from `xcrun simctl runtime list -j`.
    public struct SimulatorRuntime: Equatable {
        public var id: String
        public var version: String
        public var bytes: Int64
        /// Nil when no simulator of this runtime was ever started.
        public var lastUsed: Date?
        public init(id: String, version: String, bytes: Int64, lastUsed: Date?) {
            self.id = id; self.version = version; self.bytes = bytes; self.lastUsed = lastUsed
        }
    }

    /// Runtimes that no simulator used in the last `days`. The newest version always
    /// stays: it is the one Xcode builds for, even after a long break.
    public static func unusedRuntimes(_ runtimes: [SimulatorRuntime], now: Date = Date(), days: Double = 90) -> [SimulatorRuntime] {
        func numbers(_ v: String) -> [Int] { v.split(separator: ".").compactMap { Int($0) } }
        guard let newest = runtimes.max(by: { numbers($0.version).lexicographicallyPrecedes(numbers($1.version)) }) else { return [] }
        return runtimes.filter { r in
            r.id != newest.id && isStale(lastActivity: r.lastUsed ?? .distantPast, now: now, days: days)
        }
    }

    /// True for a mounted disk image that `tidy` may offer to eject. The images of the
    /// Xcode simulators stay: CoreSimulator mounts them and needs them.
    public static func isEjectable(imagePath: String, mountPoints: [String]) -> Bool {
        guard !mountPoints.isEmpty else { return false }
        let system = ["/System/", "/Library/Developer/"]
        if system.contains(where: imagePath.hasPrefix) { return false }
        return !mountPoints.contains { m in system.contains(where: m.hasPrefix) }
    }

    /// True for an image file that can go to the Trash after its disk is ejected: one in
    /// a temporary folder or in Downloads. Other images may hold the person's own files.
    public static func isDisposableImage(path: String, home: String) -> Bool {
        let p = (path as NSString).standardizingPath
        return p.hasPrefix("/var/folders/") || p.hasPrefix("/private/var/folders/") || p.hasPrefix("/tmp/") || p.hasPrefix("/private/tmp/")
            || p.hasPrefix(home + "/Downloads/")
    }

    /// File extensions of local AI model weights.
    public static let modelExtensions: Set<String> = ["safetensors", "gguf", "ckpt", "pth", "onnx", "mlmodelc", "bin"]

    /// True for a file that `tidy models` lists: a model extension and at least 500 MB.
    /// `.bin` is a common name for other things, so it needs 2 GB.
    public static func isModelFile(extension ext: String, bytes: UInt64) -> Bool {
        guard modelExtensions.contains(ext) else { return false }
        return bytes >= (ext == "bin" ? 2_000_000_000 : 500_000_000)
    }
}
