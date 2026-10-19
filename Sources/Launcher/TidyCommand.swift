import AppKit
import LauncherCore

/// `tidy` finds disk space that can be freed and frees it one Return at a time.
///
/// It scans in the background and never clears anything without a Return press.
/// Only the locations listed here are touched. Folders go to the Trash; tool
/// caches are cleaned by their own tools (npm, pnpm, pip, brew, simctl, docker).
/// "Clear All Safe" only runs the rows marked safe: build output and package
/// caches that rebuild by themselves. Downloads, old projects, app caches,
/// Docker and iCloud each need their own Return.
final class TidyCommand {
    static let keywords: Set<String> = ["tidy"]

    struct Item {
        var id: String
        var title: String
        var note: String
        var bytes: Int64
        var safe: Bool
        var icon: String
        var clear: (() -> Void)?
    }

    private(set) var items: [Item] = []
    private(set) var scanning = false
    private(set) var busy: String?
    private var lastScan: Date?
    private var freeBytes: Int64 = 0
    private var totalBytes: Int64 = 0
    private var trashBytes: Int64?
    private var downloads: [(url: URL, bytes: Int64, added: Date)] = []
    private var projects: [(name: String, folders: [URL], bytes: Int64, idle: Int)] = []
    private var caches: [(url: URL, bytes: Int64)] = []
    private var icloud: (files: [URL], bytes: Int64) = ([], 0)
    private var models: [(url: URL, bytes: Int64, opened: Date?)] = []

    private let home = Paths.home
    private let queue = DispatchQueue(label: "kea.tidy", qos: .utility)
    private let projectRoots: [String]

    /// True while a scan or a clear runs, so the list keeps refreshing.
    var isLive: Bool { scanning || busy != nil }

    init(projectRoots: [String] = ["~/Developer", "~/Projects"]) {
        self.projectRoots = projectRoots
    }

    // MARK: Scanning

    /// Scans when the last scan is older than 10 minutes (or when forced).
    func scanIfNeeded(force: Bool = false) {
        guard !scanning, busy == nil else { return }
        if !force, let lastScan, Date().timeIntervalSince(lastScan) < 600 { return }
        scanning = true
        queue.async { [self] in
            let found = scan()
            DispatchQueue.main.async {
                self.items = found
                self.scanning = false
                self.lastScan = Date()
            }
        }
    }

    private func path(_ p: String) -> URL { home.appendingPathComponent(p) }

    /// Runs on the tidy queue. Each part publishes as soon as it is measured.
    private func scan() -> [Item] {
        var out: [Item] = []
        func publish(_ item: Item?) {
            guard let item, item.bytes > 1_000_000 || item.clear == nil else { return }
            out.append(item)
            let snapshot = out
            DispatchQueue.main.async { self.items = snapshot }
        }

        // Measured here, stored on the main thread, which is the only one that reads them.
        func onMain(_ body: () -> Void) { DispatchQueue.main.sync(execute: body) }
        if let v = try? URL(fileURLWithPath: "/System/Volumes/Data").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            onMain {
                freeBytes = v.volumeAvailableCapacityForImportantUsage ?? 0
                totalBytes = Int64(v.volumeTotalCapacity ?? 0)
            }
        }

        // Safe: rebuildable output and package caches.
        let derived = path("Library/Developer/Xcode/DerivedData")
        publish(item("derived", "Xcode DerivedData", "Build output; Xcode rebuilds it", [derived], safe: true, icon: "hammer") { [self] in trashContents(of: derived) })
        let npm = path(".npm")
        publish(item("npm", "npm cache", "Packages download again when needed", [npm], safe: true, icon: "shippingbox") { [self] in run("npm", ["cache", "clean", "--force"]) })
        // Not `pnpm store prune`: with APFS clones every store file has one link, so
        // pnpm 9 would count all packages as unused. Whole stores go, but only stores
        // that no project active in the last 30 days uses.
        let (unusedStores, keptStores) = pnpmStores()
        if !unusedStores.isEmpty {
            let kept = keptStores.isEmpty ? "" : " · keeps \(keptStores.map(shortPath).joined(separator: ", "))"
            publish(item("pnpm", "Unused pnpm stores", "No project from the last 30 days uses them\(kept)", unusedStores, safe: true, icon: "shippingbox") { [self] in
                unusedStores.forEach(trash)
            })
        }
        let pip = path("Library/Caches/pip")
        publish(item("pip", "pip cache", "Packages download again when needed", [pip], safe: true, icon: "shippingbox") { [self] in run("pip3", ["cache", "purge"]) })
        let swiftpm = path("Library/Caches/org.swift.swiftpm")
        publish(item("swiftpm", "Swift package cache", "Packages download again when needed", [swiftpm], safe: true, icon: "swift") { [self] in trashContents(of: swiftpm) })
        let brew = path("Library/Caches/Homebrew")
        publish(item("brew", "Homebrew downloads", "brew cleanup removes old downloads and versions", [brew], safe: true, icon: "mug") { [self] in run("brew", ["cleanup", "--prune=all", "-s"]) })
        let support = path("Library/Developer/Xcode/iOS DeviceSupport")
        let stale = Tidy.staleDeviceSupport((try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []).map { support.appendingPathComponent($0) }
        if !stale.isEmpty {
            publish(item("devicesupport", "Old iOS DeviceSupport", "Keeps the 2 newest versions per device", stale, safe: true, icon: "iphone") { [self] in stale.forEach(trash) })
        }
        let unavailable = unavailableSimulators()
        if !unavailable.isEmpty {
            publish(item("simulators", "Unavailable simulators", "\(unavailable.count) devices whose runtime is gone", unavailable, safe: true, icon: "ipad") { [self] in run("xcrun", ["simctl", "delete", "unavailable"]) })
        }

        // Review: each needs its own Return.
        let cloud = scanICloud()
        onMain { icloud = cloud }
        if cloud.bytes > 0 {
            publish(Item(id: "icloud", title: "Make Old iCloud Drive Files Cloud-Only",
                         note: "\(cloud.files.count) uploaded files not opened in 30 days · they stay in Finder and download when opened",
                         bytes: cloud.bytes, safe: false, icon: "icloud.and.arrow.up") { [self] in evictICloud() })
        }
        let dl = scanDownloads()
        onMain { downloads = dl }
        if !dl.isEmpty {
            publish(Item(id: "downloads", title: "Review Downloads", note: "\(dl.count) items added more than 30 days ago · Return lists them",
                         bytes: dl.reduce(0) { $0 + $1.bytes }, safe: false, icon: "arrow.down.circle", clear: nil))
        }
        let pr = scanProjects()
        onMain { projects = pr }
        if !pr.isEmpty {
            publish(Item(id: "projects", title: "Review Old Projects", note: "Build folders in \(pr.count) projects untouched for 60 days · Return lists them",
                         bytes: pr.reduce(0) { $0 + $1.bytes }, safe: false, icon: "folder", clear: nil))
        }
        let ca = scanCaches()
        onMain { caches = ca }
        if !ca.isEmpty {
            publish(Item(id: "caches", title: "Review App Caches", note: "Apps rebuild them but run slower for a while · Return lists them",
                         bytes: ca.reduce(0) { $0 + $1.bytes }, safe: false, icon: "archivebox", clear: nil))
        }
        if let reclaim = dockerReclaimable(), reclaim > 0 {
            publish(Item(id: "docker", title: "Docker: Remove Unused Images and Containers", note: "docker system prune; volumes are kept",
                         bytes: reclaim, safe: false, icon: "shippingbox.circle") { [self] in run("docker", ["system", "prune", "-f"]) })
        }
        let runtimes = unusedRuntimes()
        if !runtimes.isEmpty {
            publish(Item(id: "runtimes", title: "Delete Unused Simulator Runtimes",
                         note: "\(runtimes.map(\.name).joined(separator: ", ")) · no simulator used them for 90 days · deleted for good; Xcode can download them again",
                         bytes: runtimes.reduce(0) { $0 + $1.runtime.bytes }, safe: false, icon: "iphone.slash") { [self] in
                runtimes.forEach { run("xcrun", ["simctl", "runtime", "delete", $0.runtime.id]) }
                run("xcrun", ["simctl", "delete", "unavailable"])
            })
        }
        let images = mountedImages()
        if !images.isEmpty {
            let disposable = images.filter { Tidy.isDisposableImage(path: $0.image.path, home: home.path) }
            let names = images.map { $0.image.lastPathComponent }.joined(separator: ", ")
            publish(Item(id: "images", title: "Eject \(images.count) Mounted Disk Image\(images.count == 1 ? "" : "s")",
                         note: "\(names) · an image in use stays · the image files in temporary folders and Downloads go to the Trash",
                         bytes: max(du(disposable.map(\.image)), 1_000_001), safe: false, icon: "eject") { [self] in
                for i in images {
                    let result = Proc.run("/usr/bin/hdiutil", ["detach", i.device])
                    Log.write("tidy: eject \(i.image.lastPathComponent): \(result.status == 0 ? "done" : String(result.output.prefix(120)))")
                    if result.status == 0, Tidy.isDisposableImage(path: i.image.path, home: home.path) { trash(i.image) }
                }
            })
        }
        let mo = scanModels()
        onMain { models = mo }
        if !mo.isEmpty {
            publish(Item(id: "models", title: "Review AI Model Files", note: "\(mo.count) large model files · Return lists them",
                         bytes: mo.reduce(0) { $0 + $1.bytes }, safe: false, icon: "cpu", clear: nil))
        }
        let t = du([path(".Trash")])
        onMain { trashBytes = t }
        return out
    }

    private func item(_ id: String, _ title: String, _ note: String, _ paths: [URL], safe: Bool, icon: String, clear: @escaping () -> Void) -> Item? {
        let bytes = du(paths)
        return bytes > 0 ? Item(id: id, title: title, note: note, bytes: bytes, safe: safe, icon: icon, clear: clear) : nil
    }

    /// Disk use in bytes, via du (much faster than walking the tree in Swift). 0 when unreadable.
    private func du(_ urls: [URL]) -> Int64 {
        let existing = urls.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return 0 }
        let out = runCapture("/usr/bin/du", ["-sk"] + existing)
        return out.split(separator: "\n").reduce(0) { sum, line in
            sum + (Int64(line.split(separator: "\t").first ?? "") ?? 0) * 1024
        }
    }

    private func shortPath(_ u: URL) -> String { u.path.replacingOccurrences(of: home.path, with: "~") }

    /// Every pnpm store on disk, split into ones no active project uses and ones to keep.
    private func pnpmStores() -> (unused: [URL], kept: [URL]) {
        let fm = FileManager.default
        var stores: [URL] = []
        for parent in [path("Library/pnpm/store"), path(".pnpm-store")] {
            for v in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] where v.hasPrefix("v") {
                stores.append(parent.appendingPathComponent(v))
            }
        }
        guard !stores.isEmpty else { return ([], []) }
        // Installed projects record their store in node_modules/.modules.yaml.
        var records = Set<String>()
        for root in projectRoots.map(Paths.expand) where fm.fileExists(atPath: root) {
            let out = runCapture("/usr/bin/find", [root, "-maxdepth", "4", "-path", "*/node_modules/.modules.yaml", "-not", "-path", "*/node_modules/*/node_modules/*"])
            out.split(separator: "\n").forEach { records.insert(String($0)) }
        }
        // Newer pnpm also keeps links to its projects inside the store.
        for store in stores {
            let reg = store.appendingPathComponent("projects")
            for link in (try? fm.contentsOfDirectory(atPath: reg.path)) ?? [] {
                if let target = try? fm.destinationOfSymbolicLink(atPath: reg.appendingPathComponent(link).path) {
                    let project = URL(fileURLWithPath: target, relativeTo: reg).standardizedFileURL
                    records.insert(project.appendingPathComponent("node_modules/.modules.yaml").path)
                }
            }
        }
        var installs: [Tidy.PnpmInstall] = []
        for record in records {
            guard let text = try? String(contentsOfFile: record, encoding: .utf8),
                  let store = Tidy.pnpmStoreDir(fromModulesYaml: text) else { continue }
            let project = URL(fileURLWithPath: record).deletingLastPathComponent().deletingLastPathComponent()
            let installed = (try? fm.attributesOfItem(atPath: record)[.modificationDate] as? Date) ?? .distantPast
            installs.append(.init(store: store, lastActivity: max(installed, lastActivity(project) ?? .distantPast)))
        }
        let unused = Set(Tidy.unusedPnpmStores(stores.map(\.path), installs: installs))
        return (stores.filter { unused.contains($0.path) }, stores.filter { !unused.contains($0.path) })
    }

    private func scanDownloads() -> [(url: URL, bytes: Int64, added: Date)] {
        let dir = path("Downloads")
        let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .contentModificationDateKey]
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: keys)
            let added = v?.addedToDirectoryDate ?? v?.contentModificationDate ?? Date()
            return added < cutoff ? (u, du([u]), added) : nil
        }.sorted { $0.bytes > $1.bytes }
    }

    private func scanProjects() -> [(name: String, folders: [URL], bytes: Int64, idle: Int)] {
        var found: [(String, [URL], Int64, Int)] = []
        let fm = FileManager.default
        for root in projectRoots.map(Paths.expand) {
            for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !name.hasPrefix(".") {
                let project = URL(fileURLWithPath: root).appendingPathComponent(name)
                let folders = Tidy.buildFolders.map { project.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
                guard !folders.isEmpty, let last = lastActivity(project), Tidy.isStale(lastActivity: last) else { continue }
                let bytes = du(folders)
                if bytes > 50_000_000 { found.append((name, folders, bytes, Int(Date().timeIntervalSince(last) / 86400))) }
            }
        }
        return found.sorted { $0.2 > $1.2 }.map { (name: $0.0, folders: $0.1, bytes: $0.2, idle: $0.3) }
    }

    /// The last git commit, or else the newest top-level file change.
    private func lastActivity(_ project: URL) -> Date? {
        if FileManager.default.fileExists(atPath: project.appendingPathComponent(".git").path) {
            let t = runCapture("/usr/bin/git", ["-C", project.path, "log", "-1", "--format=%ct"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let s = Double(t) { return Date(timeIntervalSince1970: s) }
        }
        let items = (try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items.filter { !Tidy.buildFolders.contains($0.lastPathComponent) }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    /// Caches not covered by a safe row, largest first.
    private func scanCaches() -> [(url: URL, bytes: Int64)] {
        let dir = path("Library/Caches")
        let handled: Set<String> = ["pip", "org.swift.swiftpm", "Homebrew", "pnpm"]
        let urls = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { !handled.contains($0.lastPathComponent) && !$0.lastPathComponent.hasPrefix(".") }
        return urls.map { (url: $0, bytes: du([$0])) }.filter { $0.bytes > 100_000_000 }.sorted { $0.bytes > $1.bytes }
    }

    private func scanICloud() -> (files: [URL], bytes: Int64) {
        let root = path("Library/Mobile Documents/com~apple~CloudDocs")
        guard FileManager.default.fileExists(atPath: root.path) else { return ([], 0) }
        let keys: [URLResourceKey] = [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey, .totalFileAllocatedSizeKey, .contentAccessDateKey, .isRegularFileKey]
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        var files: [URL] = []
        var bytes: Int64 = 0
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let u = e?.nextObject() as? URL {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  v.ubiquitousItemDownloadingStatus == .current, v.ubiquitousItemIsUploaded == true,
                  (v.contentAccessDate ?? .distantPast) < cutoff else { continue }
            files.append(u)
            bytes += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return (files, bytes)
    }

    /// Simulator runtimes that were not used for 90 days, with a name such as "iOS 18.6".
    private func unusedRuntimes() -> [(runtime: Tidy.SimulatorRuntime, name: String)] {
        let json = runCapture("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"])
        guard let data = json.data(using: .utf8), let all = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        let dates = ISO8601DateFormatter()
        var names: [String: String] = [:]
        let runtimes = all.values.compactMap { r -> Tidy.SimulatorRuntime? in
            guard let id = r["identifier"] as? String, let version = r["version"] as? String, r["state"] as? String == "Ready",
                  r["deletable"] as? Bool != false else { return nil }
            // "com.apple.CoreSimulator.SimRuntime.iOS-26-4" → "iOS"
            let platform = (r["runtimeIdentifier"] as? String)?.split(separator: ".").last?.split(separator: "-").first.map(String.init) ?? "Simulator"
            names[id] = "\(platform) \(version)"
            return Tidy.SimulatorRuntime(id: id, version: version, bytes: (r["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                                         lastUsed: (r["lastUsedAt"] as? String).flatMap(dates.date(from:)))
        }
        return Tidy.unusedRuntimes(runtimes).map { ($0, names[$0.id] ?? $0.version) }
    }

    /// Mounted disk images that are not part of the system, with the device to eject.
    private func mountedImages() -> [(image: URL, device: String)] {
        let out = Proc.run("/usr/bin/hdiutil", ["info", "-plist"]).output
        guard let start = out.range(of: "<?xml"), let data = String(out[start.lowerBound...]).data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        return images.compactMap { image in
            guard let path = image["image-path"] as? String, let entities = image["system-entities"] as? [[String: Any]] else { return nil }
            let mounts = entities.compactMap { $0["mount-point"] as? String }
            guard Tidy.isEjectable(imagePath: path, mountPoints: mounts),
                  let device = entities.compactMap({ $0["dev-entry"] as? String }).min(by: { $0.count < $1.count }) else { return nil }
            return (URL(fileURLWithPath: path), device)
        }
    }

    /// Large AI model files in the project folders and the usual model caches, largest first.
    private func scanModels() -> [(url: URL, bytes: Int64, opened: Date?)] {
        var found: [(URL, Int64, Date?)] = []
        let roots = projectRoots.map(Paths.expand) + [path(".cache").path, path("Library/Application Support").path, path("Downloads").path]
        for root in roots where FileManager.default.fileExists(atPath: root) {
            guard let tree = DiskScanner(root: root).run() else { continue }
            for node in 1 ..< Int32(tree.count) where !tree.isDirectory(node) {
                guard Tidy.isModelFile(extension: tree.extensions[Int(tree.ext[Int(node)])], bytes: tree.size[Int(node)]) else { continue }
                let url = URL(fileURLWithPath: tree.path(of: node))
                found.append((url, Int64(tree.size[Int(node)]), try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate))
            }
        }
        return found.sorted { $0.1 > $1.1 }.map { (url: $0.0, bytes: $0.1, opened: $0.2) }
    }

    private func unavailableSimulators() -> [URL] {
        let json = runCapture("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = obj["devices"] as? [String: [[String: Any]]] else { return [] }
        return devices.values.flatMap { $0 }.compactMap { ($0["dataPath"] as? String).map { URL(fileURLWithPath: $0).deletingLastPathComponent() } }
    }

    /// Reclaimable bytes Docker reports, or nil when Docker is not running.
    private func dockerReclaimable() -> Int64? {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.docker.docker" }) else { return nil }
        let out = runCapture(tool("docker") ?? "/usr/local/bin/docker", ["system", "df", "--format", "{{.Reclaimable}}"])
        var total: Int64 = 0
        for line in out.split(separator: "\n") {
            // "12.3GB (60%)"
            let token = line.split(separator: " ").first.map(String.init) ?? ""
            let units: [(String, Double)] = [("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("B", 1)]
            for (u, m) in units where token.hasSuffix(u) {
                total += Int64((Double(token.dropLast(u.count)) ?? 0) * m)
                break
            }
        }
        return total
    }

    /// `Kea --tidy-scan`: runs one scan and prints each row. It clears nothing.
    static func printScan() {
        let tidy = TidyCommand()
        let done = DispatchSemaphore(value: 0)
        var found: [Item] = []
        tidy.queue.async {
            found = tidy.scan()
            done.signal()
        }
        // The scan stores some values on the main thread, so keep that thread turning.
        while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        for item in found { print("\(item.id)\t\(Tidy.size(item.bytes))\t\(item.safe ? "safe" : "review")\t\(item.title)\t\(item.note)") }
        for m in tidy.models.prefix(8) { print("model\t\(Tidy.size(m.bytes))\t\(m.url.path)") }
    }

    // MARK: Clearing

    private func trash(_ url: URL) {
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        catch { Log.write("tidy: could not trash \(url.path): \(error.localizedDescription)") }
    }

    private func trashContents(of dir: URL) {
        for u in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] { trash(u) }
    }

    private func evictICloud() {
        var done = 0
        let files = DispatchQueue.main.sync { icloud.files }
        for u in files {
            if (try? FileManager.default.evictUbiquitousItem(at: u)) != nil { done += 1 }
        }
        Log.write("tidy: made \(done) of \(files.count) iCloud files cloud-only")
    }

    private func tool(_ name: String) -> String? {
        ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"].map { $0 + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func run(_ name: String, _ args: [String]) {
        guard let exe = tool(name) else { Log.write("tidy: \(name) not found"); return }
        let out = runCapture(exe, args)
        Log.write("tidy: \(name) \(args.joined(separator: " ")): \(out.suffix(200).trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    @discardableResult
    private func runCapture(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs clears off the main thread, one after another, then scans again.
    private func perform(_ label: String, _ work: [() -> Void]) {
        guard busy == nil else { return }
        busy = label
        queue.async { [self] in
            work.forEach { $0() }
            DispatchQueue.main.async {
                self.busy = nil
                self.scanIfNeeded(force: true)
            }
        }
    }

    // MARK: Results

    private static func icon(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }

    func results(argument: String) -> [Result] {
        scanIfNeeded()
        switch argument.trimmingCharacters(in: .whitespaces).lowercased() {
        case "downloads": return downloadRows()
        case "projects": return projectRows()
        case "caches": return cacheRows()
        case "models": return modelRows()
        default: return mainRows()
        }
    }

    private func mainRows() -> [Result] {
        let safe = items.filter { $0.safe && $0.clear != nil }
        let safeBytes = safe.reduce(Int64(0)) { $0 + $1.bytes }
        var status = "\(Tidy.size(freeBytes)) free of \(Tidy.size(totalBytes))"
        if let busy { status = "\(busy)…" } else if scanning { status += " · scanning…" }
        var rows = [Result(id: "tidy:status", title: safeBytes > 0 ? "\(Tidy.size(safeBytes)) can be cleared safely" : (scanning ? "Looking for space…" : "Nothing safe to clear"),
                           subtitle: status, icon: Self.icon("internaldrive"), action: .none)]
        if !safe.isEmpty, busy == nil {
            rows.append(Result(id: "tidy:all", title: "Clear All Safe · \(Tidy.size(safeBytes))",
                               subtitle: safe.map(\.title).joined(separator: ", "), icon: Self.icon("sparkles"),
                               action: .custom { [weak self] in self?.perform("Clearing \(safe.count) items", safe.compactMap(\.clear)) }))
        }
        for i in items {
            let action: ResultAction
            if let clear = i.clear {
                action = busy == nil ? .custom { [weak self] in self?.perform("Clearing \(i.title)", [clear]) } : .none
            } else {
                action = .fill("tidy \(i.id) ")
            }
            rows.append(Result(id: "tidy:\(i.id)", title: "\(i.title) · \(Tidy.size(i.bytes))",
                               subtitle: (i.safe ? "Safe · " : "") + i.note, icon: Self.icon(i.icon), action: action))
        }
        if !scanning {
            let size = trashBytes.map { $0 > 0 ? " · \(Tidy.size($0))" : "" } ?? ""
            rows.append(Result(id: "tidy:trash", title: "Empty Trash\(size)",
                               subtitle: "Cleared items stay in the Trash and use space until it is emptied · asks first",
                               icon: Self.icon("trash"), action: .custom { [weak self] in self?.emptyTrash() }))
        }
        return rows
    }

    private func emptyTrash() {
        let a = NSAlert()
        a.messageText = "Empty the Trash?"
        a.informativeText = "This permanently deletes everything in the Trash" + (trashBytes.map { $0 > 0 ? " (\(Tidy.size($0)))." : "." } ?? ".")
        a.addButton(withTitle: "Empty Trash")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
        if let error { Log.write("tidy: empty trash failed: \(error)") } else { Log.write("tidy: trash emptied") }
        scanIfNeeded(force: true)
    }

    private func downloadRows() -> [Result] {
        if downloads.isEmpty { return [Result(id: "tidy:dl:none", title: scanning ? "Scanning Downloads…" : "No downloads older than 30 days", subtitle: nil, icon: Self.icon("arrow.down.circle"), action: .none)] }
        return downloads.prefix(60).map { d in
            let days = Int(Date().timeIntervalSince(d.added) / 86400)
            return Result(id: "tidy:dl:\(d.url.path)", title: d.url.lastPathComponent,
                          subtitle: "\(Tidy.size(d.bytes)) · added \(days) days ago · Cmd+Y preview · fn+Delete to Trash",
                          icon: IconLoader.shared.icon(forPath: d.url.path), action: .openPath(d.url.path), revealPath: d.url.path,
                          onDelete: { [weak self] in
                              self?.trash(d.url)
                              self?.downloads.removeAll { $0.url == d.url }
                          })
        }
    }

    private func projectRows() -> [Result] {
        if projects.isEmpty { return [Result(id: "tidy:pr:none", title: scanning ? "Scanning projects…" : "No old projects with build folders", subtitle: nil, icon: Self.icon("folder"), action: .none)] }
        return projects.map { p in
            let names = p.folders.map(\.lastPathComponent).joined(separator: ", ")
            let clear = { [weak self] in
                p.folders.forEach { self?.trash($0) }
                self?.projects.removeAll { $0.name == p.name }
            }
            return Result(id: "tidy:pr:\(p.name)", title: "\(p.name) · \(Tidy.size(p.bytes))",
                          subtitle: "\(names) · no change for \(p.idle) days · Return moves them to the Trash",
                          icon: Self.icon("folder"), action: .custom(clear), revealPath: p.folders.first?.deletingLastPathComponent().path,
                          onDelete: clear)
        }
    }

    private func modelRows() -> [Result] {
        if models.isEmpty { return [Result(id: "tidy:mo:none", title: scanning ? "Looking for model files…" : "No large AI model files", subtitle: nil, icon: Self.icon("cpu"), action: .none)] }
        return models.prefix(60).map { m in
            let opened = m.opened.map { "last opened \(Int(Date().timeIntervalSince($0) / 86400)) days ago" } ?? "never opened"
            return Result(id: "tidy:mo:\(m.url.path)", title: "\(m.url.lastPathComponent) · \(Tidy.size(m.bytes))",
                          subtitle: "\(shortPath(m.url.deletingLastPathComponent())) · \(opened) · Return shows it in Finder · fn+Delete to Trash",
                          icon: Self.icon("cpu"), action: .custom { NSWorkspace.shared.activateFileViewerSelecting([m.url]) }, revealPath: m.url.path,
                          onDelete: { [weak self] in
                              self?.trash(m.url)
                              self?.models.removeAll { $0.url == m.url }
                          })
        }
    }

    private func cacheRows() -> [Result] {
        if caches.isEmpty { return [Result(id: "tidy:ca:none", title: scanning ? "Scanning caches…" : "No large app caches", subtitle: nil, icon: Self.icon("archivebox"), action: .none)] }
        // "Google" belongs to com.google.Chrome, "Codex" to com.openai.codex: match the
        // whole bundle id or any part of it.
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() }
        let parts = Set(running + running.flatMap { $0.split(separator: ".").map(String.init) })
        return caches.prefix(30).map { c in
            let name = c.url.lastPathComponent
            let inUse = name.count >= 3 && parts.contains(name.lowercased())
            let clear = { [weak self] in
                self?.trash(c.url)
                self?.caches.removeAll { $0.url == c.url }
            }
            return Result(id: "tidy:ca:\(name)", title: "\(name) · \(Tidy.size(c.bytes))",
                          subtitle: inUse ? "The app is running; quit it first" : "Return moves it to the Trash; the app rebuilds it",
                          icon: Self.icon("archivebox"), action: inUse ? .none : .custom(clear), revealPath: c.url.path,
                          onDelete: inUse ? nil : clear)
        }
    }
}

extension TidyCommand {
    var command: KeaCommand {
        KeaCommand(id: "tidy", name: "Tidy (Disk Space)", keywords: Self.keywords,
                   help: [.init(keyword: "tidy", summary: "Find and free disk space: caches, build output, old downloads, iCloud, simulator runtimes, model files", example: "tidy · tidy downloads · tidy models")],
                   // Keep refreshing while a scan or a clear runs.
                   live: (0.75, { [unowned self] in isLive }),
                   results: { [unowned self] in results(argument: $0.argument) })
    }
}
