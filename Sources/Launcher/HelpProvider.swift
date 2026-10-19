import AppKit
import LauncherCore

/// `help` lists every keyword of every enabled command. Return puts the keyword in the search field.
enum HelpProvider {
    static let keywords: Set<String> = ["help", "?"]

    struct Entry { var keyword: String; var summary: String; var example: String }

    /// General lines, then each command's own lines in registry order (Commands.swift),
    /// then script commands `help`'s own line is last.
    static func entries(commands: [KeaCommand], config: Config, scripts: ScriptCommands) -> [Entry] {
        var e: [Entry] = [
            Entry(keyword: "", summary: "Type to find apps, files, folders, and settings panes", example: "chrome · notes · bluetooth"),
            Entry(keyword: "", summary: "Calculator and unit conversion inline", example: "12*4.5 · 10 mi in km · 100 usd in eur"),
        ]
        e += commands.filter { $0.id != "help" }.flatMap(\.help)
        for c in scripts.commands {
            e.append(Entry(keyword: c.manifest.keyword, summary: c.manifest.title + (c.manifest.subtitle.map { " · \($0)" } ?? ""),
                           example: c.manifest.mode == .list ? "\(c.manifest.keyword) text" : c.manifest.keyword))
        }
        e += commands.filter { $0.id == "help" }.flatMap(\.help)
        return e
    }

    static func results(filter: String, commands: [KeaCommand], config: Config, scripts: ScriptCommands) -> [Result] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let icon = IconLoader.shared.icon(forSpec: "sf:questionmark.circle")
        let keys = Result(id: "help:keys", title: "Keys",
                          subtitle: "Return opens · Cmd+Return reveals in Finder · Cmd+Y Quick Look · fn+Delete removes · Tab completes a keyword · Cmd+, settings · Esc clears, then closes",
                          icon: IconLoader.shared.icon(forSpec: "sf:keyboard"), action: .none, expanded: true)
        let rows = entries(commands: commands, config: config, scripts: scripts).filter { e in
            f.isEmpty || e.keyword.contains(f) || e.summary.lowercased().contains(f) || e.example.lowercased().contains(f)
        }.map { e -> Result in
            let title = e.keyword.isEmpty ? e.summary : "\(e.keyword)  —  \(e.summary)"
            let action: ResultAction = e.keyword.isEmpty ? .none : .fill(e.keyword + " ")
            return Result(id: "help:\(e.keyword):\(e.summary)", title: title, subtitle: "e.g. \(e.example)", icon: icon, action: action)
        }
        return (f.isEmpty ? [keys] : []) + rows
    }
}
