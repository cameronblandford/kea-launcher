import AppKit
import LauncherCore

/// Runs the same search pipeline as the panel, without a window, and prints
/// the results as text. Waits briefly for Spotlight so file and app results land.
enum HeadlessQuery {
    static func run(_ text: String) {
        Paths.ensureRoot()
        let config = Config.load(from: Paths.config)
        let apps = AppIndex(folders: config.appFolders)
        apps.start()
        let files = config.fileSearch.enabled
            ? FileSearch(scopes: config.fileSearch.scopes, maxResults: config.fileSearch.maxResults) : nil
        let scripts = ScriptCommands()
        scripts.reload()
        let clipboard = ClipboardHistory(limit: config.clipboard.limit)
        let rates = RatesStore()
        let frecency = (try? Data(contentsOf: Paths.frecency)).flatMap { try? Frecency(data: $0) } ?? Frecency()
        let coordinator = SearchCoordinator(apps: apps, files: files, scripts: scripts, frecency: frecency, config: config,
                                            clipboard: clipboard, rates: rates)
        coordinator.personal.startIndexing()

        var latest: [Result] = []
        coordinator.onResults = { latest = $0 }

        // Let the app scan and Spotlight app query settle, then search and wait for async providers.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        print("apps indexed: \(apps.apps.count), commands: \(scripts.commands.count)")
        var t0 = CFAbsoluteTimeGetCurrent()
        coordinator.update(text: text)
        let cold = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        coordinator.update(text: text + " ")
        t0 = CFAbsoluteTimeGetCurrent()
        coordinator.update(text: text)
        let warm = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        print("main-thread cost of update: cold \(cold) ms, warm \(warm) ms")
        // KEA_QUERY_WAIT=60 waits longer, for slow providers such as `tidy`.
        let wait = Double(ProcessInfo.processInfo.environment["KEA_QUERY_WAIT"] ?? "") ?? 2.0
        RunLoop.main.run(until: Date().addingTimeInterval(wait))

        print("query: \(text)")
        for (i, r) in latest.enumerated() {
            print("\(i + 1). \(r.title)  [\(r.id)]  \(r.subtitle ?? "")" + (r.keys.isEmpty ? "" : "  keys: " + r.keys.joined(separator: " ")))
        }
        exit(0)
    }
}
