import AppKit
import LauncherCore

/// `uninstall <app>` finds an app and the files it left in the Library folders (settings,
/// caches, saved state, its folder in the home folder), shows the list with sizes, and
/// after a confirmation moves all of it to the Trash. Nothing is deleted for good, and
/// nothing outside the home folder is touched except the app itself.
enum UninstallCommand {
    struct Item {
        var url: URL
        var bytes: Int64
    }

    struct Plan {
        var app: AppEntry
        var items: [Item]
        /// Command-line links that point into the app (`/usr/local/bin/ollama`).
        var links: [String]
        var total: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }

    private static func icon(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }
    private static func bundleId(_ app: AppEntry) -> String? { Bundle(path: app.path)?.bundleIdentifier }

    private static func isRunning(_ app: AppEntry) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: app.path).standardizedFileURL.path }
    }

    static func results(argument: String, apps: [AppEntry]) -> [Result] {
        let term = argument.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else {
            return [Result(id: "uninstall:hint", title: "Type the name of an app", subtitle: "For example: uninstall ollama · the app and its leftover files go to the Trash after you confirm",
                           icon: icon("trash"), action: .none)]
        }
        // Only installed apps: the index also has apps in Downloads and inside other apps' folders.
        let folders = ["/Applications/", Paths.home.path + "/Applications/"]
        let matches = apps.filter { app in folders.contains { app.path.hasPrefix($0) } }.compactMap { app in FuzzyMatcher.score(query: term, candidate: app.name).map { (app, $0) } }
            .sorted { $0.1 > $1.1 }.prefix(6).map(\.0)
            .filter { !Uninstall.isProtected(path: $0.path, bundleId: bundleId($0)) }
        guard !matches.isEmpty else {
            return [Result(id: "uninstall:none", title: "No app found for \(term)", subtitle: "Apps that are part of macOS cannot be uninstalled", icon: icon("trash"), action: .none)]
        }
        return matches.map { app in
            let running = isRunning(app)
            return Result(id: "uninstall:\(app.path)", title: "Uninstall \(app.name)",
                          subtitle: running ? "\(app.name) is running; quit it first" : "\(app.path) · Return lists its files and asks first",
                          icon: IconLoader.shared.icon(forPath: app.path), action: running ? .none : .custom { review(app) }, revealPath: app.path)
        }
    }

    /// Everything that belongs to the app, largest first after the app itself. Blocks
    /// (it measures sizes with `du`); call it off the main thread.
    static func plan(for app: AppEntry) -> Plan {
        let fm = FileManager.default
        let id = bundleId(app)
        let name = (app.path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        var found: [URL] = []
        let library = Paths.home.appendingPathComponent("Library")
        for folder in Uninstall.libraryFolders {
            let dir = library.appendingPathComponent(folder)
            for item in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where Uninstall.belongs(item, appName: name, bundleId: id) {
                found.append(dir.appendingPathComponent(item))
            }
        }
        if let dot = Uninstall.homeFolder(appName: name) {
            let url = Paths.home.appendingPathComponent(dot)
            if fm.fileExists(atPath: url.path) { found.append(url) }
        }
        var links: [String] = []
        for dir in ["/usr/local/bin", "/opt/homebrew/bin"] {
            for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let path = "\(dir)/\(item)"
                if let target = try? fm.destinationOfSymbolicLink(atPath: path), target.hasPrefix(app.path + "/") { links.append(path) }
            }
        }
        let rest = found.map { Item(url: $0, bytes: size($0)) }.sorted { $0.bytes > $1.bytes }
        return Plan(app: app, items: [Item(url: URL(fileURLWithPath: app.path), bytes: size(URL(fileURLWithPath: app.path)))] + rest, links: links)
    }

    private static func size(_ url: URL) -> Int64 {
        let out = Proc.run("/usr/bin/du", ["-sk", url.path]).output
        return (Int64(out.split(separator: "\t").first ?? "") ?? 0) * 1024
    }

    static func describe(_ plan: Plan) -> String {
        let home = Paths.home.path
        var lines = plan.items.map { "\(Tidy.size($0.bytes))\t\($0.url.path.replacingOccurrences(of: home, with: "~"))" }
        if !plan.links.isEmpty { lines.append("Links that will point to nothing: \(plan.links.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    private static func review(_ app: AppEntry) {
        DispatchQueue.global(qos: .userInitiated).async {
            let plan = plan(for: app)
            DispatchQueue.main.async { confirm(plan) }
        }
    }

    private static func confirm(_ plan: Plan) {
        let alert = NSAlert()
        alert.messageText = "Move \(plan.app.name) and its files to the Trash?"
        alert.informativeText = "\(plan.items.count) items, \(Tidy.size(plan.total)). You can put them back from the Trash until you empty it.\n\n\(describe(plan))"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var failed: [String] = []
        for item in plan.items {
            do { try FileManager.default.trashItem(at: item.url, resultingItemURL: nil) }
            catch {
                failed.append(item.url.lastPathComponent)
                Log.write("uninstall: could not trash \(item.url.path): \(error.localizedDescription)")
            }
        }
        Log.write("uninstall: \(plan.app.name): \(plan.items.count - failed.count) of \(plan.items.count) items to the Trash, \(Tidy.size(plan.total))")
        if failed.isEmpty, plan.links.isEmpty {
            Notify.post(title: "\(plan.app.name) is in the Trash", body: "\(plan.items.count) items, \(Tidy.size(plan.total)). Empty the Trash to free the space.")
            return
        }
        // Something is left that Kea cannot remove: say exactly what, and how.
        let after = NSAlert()
        after.messageText = failed.isEmpty ? "\(plan.app.name) is in the Trash" : "Some items could not be moved"
        var text = failed.isEmpty ? "" : "Not moved: \(failed.joined(separator: ", ")).\n\n"
        if !plan.links.isEmpty {
            let command = "sudo rm " + plan.links.map { "'\($0)'" }.joined(separator: " ")
            text += "These links now point to nothing, and only an administrator can remove them:\n\(plan.links.joined(separator: "\n"))\n\nThe command to remove them is on the clipboard:\n\(command)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
        after.informativeText = text
        after.runModal()
    }

    static func command(apps: AppIndex) -> KeaCommand {
        KeaCommand(id: "uninstall", name: "Uninstall an App", keywords: ["uninstall"],
                   help: [.init(keyword: "uninstall", summary: "Move an app and its leftover files to the Trash, after a list and a confirmation", example: "uninstall ollama")],
                   results: { [unowned apps] in results(argument: $0.argument, apps: apps.apps) })
    }
}
