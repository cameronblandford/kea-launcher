import AppKit
import LauncherCore

/// Finder settings that are worth a keystroke: hidden files, desktop icons, file
/// extensions. They show in plain search ("hidden", "desktop icons") and under `finder`.
/// Each one writes the Finder preference and restarts Finder, which is how the
/// setting takes effect.
enum FinderToggles {
    static let keyword = "finder"

    private struct Toggle {
        let id: String
        let domain: String
        let key: String
        let on: String
        let off: String
        let words: String
        let restartFinder: Bool
        let defaultOn: Bool
    }

    private static let toggles = [
        Toggle(id: "hidden", domain: "com.apple.finder", key: "AppleShowAllFiles", on: "Hide Hidden Files", off: "Show Hidden Files",
               words: "hidden files dotfiles finder", restartFinder: true, defaultOn: false),
        Toggle(id: "desktop", domain: "com.apple.finder", key: "CreateDesktop", on: "Hide Desktop Icons", off: "Show Desktop Icons",
               words: "desktop icons clean screen share finder", restartFinder: true, defaultOn: true),
        Toggle(id: "extensions", domain: "NSGlobalDomain", key: "AppleShowAllExtensions", on: "Hide File Extensions", off: "Show File Extensions",
               words: "file extensions finder", restartFinder: true, defaultOn: false),
    ]

    private static func isOn(_ t: Toggle) -> Bool {
        let domain = t.domain == "NSGlobalDomain" ? kCFPreferencesAnyApplication : t.domain as CFString
        guard let v = CFPreferencesCopyAppValue(t.key as CFString, domain) else { return t.defaultOn }
        if let b = v as? Bool { return b }
        if let s = v as? String { return ["1", "yes", "true"].contains(s.lowercased()) }
        return t.defaultOn
    }

    private static func row(_ t: Toggle) -> Result {
        let on = isOn(t)
        return Result(id: "finder:\(t.id)", title: on ? t.on : t.off, subtitle: "Finder · restarts Finder", keywordIcon: "eye",
                      action: .custom {
                          Proc.run("/usr/bin/defaults", ["write", t.domain, t.key, "-bool", on ? "false" : "true"])
                          if t.restartFinder { Proc.run("/usr/bin/killall", ["Finder"]) }
                          Log.write("finder: \(t.key) = \(!on)")
                      }, keyword: t.words)
    }

    static func results(for term: String, frecency: Frecency) -> [Result] {
        let rows = toggles.map(row)
        let ranked = Ranker.rank(rows.map { Rankable(id: $0.id, text: $0.title, secondary: $0.keyword) }, query: term, frecency: frecency)
            .filter { $0.score > 300 }
        return ranked.compactMap { r in rows.first { $0.id == r.id } }
    }

    static func list() -> [Result] { toggles.map(row) }
}

private extension Result {
    init(id: String, title: String, subtitle: String?, keywordIcon: String, action: ResultAction, keyword: String) {
        self.init(id: id, title: title, subtitle: subtitle, icon: NSImage(systemSymbolName: keywordIcon, accessibilityDescription: nil),
                  action: action, keyword: keyword)
    }
}

extension FinderToggles {
    static var command: KeaCommand {
        KeaCommand(id: "finder", name: "Finder Toggles", keywords: [keyword],
                   help: [.init(keyword: "finder", summary: "Hidden files, desktop icons, file extensions (also in normal search)", example: "finder · hidden files")],
                   search: { results(for: $0, frecency: $1) },
                   results: { _ in list() })
    }
}
