import AppKit
import LauncherCore

struct AppEntry {
    var name: String
    var path: String
}

/// Finds .app bundles by scanning known folders and asking Spotlight.
final class AppIndex {
    private(set) var apps: [AppEntry] = []
    private let folders: [String]
    private var spotlight: NSMetadataQuery?
    private var spotlightApps: [String: AppEntry] = [:]
    private var scannedApps: [String: AppEntry] = [:]
    private var timer: Timer?

    init(folders: [String]) {
        self.folders = folders.map(Paths.expand)
    }

    func start() {
        rescan()
        startSpotlight()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.rescan() }
    }

    func rescan() {
        DispatchQueue.global(qos: .utility).async { [folders] in
            var found: [String: AppEntry] = [:]
            let fm = FileManager.default
            for folder in folders {
                guard let e = fm.enumerator(at: URL(fileURLWithPath: folder),
                                            includingPropertiesForKeys: [.isDirectoryKey],
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let url as URL in e {
                    if e.level > 2 { e.skipDescendants(); continue }
                    if url.pathExtension == "app" {
                        found[url.path] = AppEntry(name: url.deletingPathExtension().lastPathComponent, path: url.path)
                        e.skipDescendants()
                    }
                }
            }
            for path in Self.alwaysInclude where fm.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path)
                found[path] = AppEntry(name: url.deletingPathExtension().lastPathComponent, path: path)
            }
            DispatchQueue.main.async {
                self.scannedApps = found
                self.merge()
            }
        }
    }

    private func startSpotlight() {
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemContentType == 'com.apple.application-bundle'")
        q.searchScopes = [NSMetadataQueryLocalComputerScope]
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { [weak self] _ in
            self?.readSpotlight()
        }
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main) { [weak self] _ in
            self?.readSpotlight()
        }
        spotlight = q
        q.start()
    }

    private func readSpotlight() {
        guard let q = spotlight else { return }
        q.disableUpdates()
        var found: [String: AppEntry] = [:]
        for i in 0..<q.resultCount {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if Self.isHelperApp(path) { continue }
            let name = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String)
                ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            found[path] = AppEntry(name: name.replacingOccurrences(of: ".app", with: ""), path: path)
        }
        q.enableUpdates()
        spotlightApps = found
        merge()
    }

    /// Spotlight also returns helper apps inside frameworks, other bundles, and
    /// game folders. Those are never something the user wants to launch by name.
    /// System apps that live among helpers but are real, launchable apps.
    static let alwaysInclude = ["/System/Library/CoreServices/Finder.app"]

    static func isHelperApp(_ path: String) -> Bool {
        if alwaysInclude.contains(path) { return false }
        if path.components(separatedBy: ".app/").count > 1 { return true }
        let junk = ["/System/Library/", ".framework/", "/Resources/", "/Helpers/",
                    "/Library/Application Support/Script Editor/", "/Library/Image Capture/",
                    "/steamapps/", "/.Trash/", "/node_modules/", "/.build/", "/DerivedData/"]
        return junk.contains { path.contains($0) }
    }

    private func merge() {
        var all = spotlightApps
        for (k, v) in scannedApps { all[k] = v }
        apps = all.values.sorted { $0.name < $1.name }
    }

    func results(for query: String, frecency: Frecency, limit: Int) -> [Result] {
        let rankables = apps.map { Rankable(id: "app:\($0.path)", text: $0.name) }
        let byID = Dictionary(uniqueKeysWithValues: apps.map { ("app:\($0.path)", $0) })
        return Ranker.rank(rankables, query: query, frecency: frecency).prefix(limit).compactMap { r in
            guard let a = byID[r.id] else { return nil }
            return Result(id: r.id, title: a.name, subtitle: a.path.replacingOccurrences(of: Paths.home.path, with: "~"),
                          icon: IconLoader.shared.icon(forPath: a.path), action: .openPath(a.path), revealPath: a.path)
        }
    }

    func entry(forID id: String) -> AppEntry? {
        guard id.hasPrefix("app:") else { return nil }
        let path = String(id.dropFirst(4))
        return apps.first { $0.path == path }
    }
}
