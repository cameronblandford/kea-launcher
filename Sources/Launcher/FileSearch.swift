import AppKit
import LauncherCore

/// Spotlight file search via NSMetadataQuery. One query in flight at a time.
final class FileSearch {
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private let scopes: [String]
    private let maxResults: Int
    private var generation = 0

    init(scopes: [String], maxResults: Int) {
        self.scopes = scopes.map(Paths.expand)
        self.maxResults = maxResults
    }

    private static let noise = ["/Library/", "/node_modules/", "/.", "/venv/", "/site-packages/",
                                "/.build/", "/DerivedData/", "/dist/", "/build/"]
    static func isNoise(_ path: String) -> Bool {
        noise.contains { path.contains($0) }
    }

    func cancel() {
        generation += 1
        query?.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        query = nil
    }

    func search(_ term: String, frecency: Frecency, completion: @escaping ([Result]) -> Void) {
        cancel()
        let gen = generation
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@ AND kMDItemContentType != 'com.apple.application-bundle'", term)
        q.searchScopes = scopes
        q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        let obs = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { [weak self] _ in
            guard let self, gen == self.generation else { return }
            q.disableUpdates()
            var entries: [(id: String, name: String, path: String)] = []
            let cap = min(q.resultCount, 400)
            for i in 0..<cap {
                guard let item = q.result(at: i) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                if Self.isNoise(path) { continue }
                let name = (item.value(forAttribute: NSMetadataItemFSNameKey) as? String) ?? URL(fileURLWithPath: path).lastPathComponent
                entries.append((id: "file:\(path)", name: name, path: path))
            }
            q.stop()
            let rankables = entries.map { Rankable(id: $0.id, text: $0.name) }
            let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let results = Ranker.rank(rankables, query: term, frecency: frecency).prefix(self.maxResults).compactMap { r -> Result? in
                guard let e = byID[r.id] else { return nil }
                return Result(id: r.id, title: e.name,
                              subtitle: e.path.replacingOccurrences(of: Paths.home.path, with: "~"),
                              icon: IconLoader.shared.icon(forPath: e.path), action: .openPath(e.path), revealPath: e.path,
                              onDelete: { Actions.trash(e.path) })
            }
            completion(results)
        }
        observers = [obs]
        query = q
        q.start()
    }
}
