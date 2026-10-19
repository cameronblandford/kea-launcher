import AppKit
import LauncherCore
import UniformTypeIdentifiers

/// `default md`, `default json`, `default browser`, `default mail`: lists the apps that
/// can open that kind of file or link, marks the current one, and Return makes another
/// app the default. Links (browser, mail) make macOS ask for confirmation itself.
enum DefaultApps {
    static let keywords: Set<String> = ["default", "defaults", "openwith"]

    private enum Target {
        case type(UTType, String)
        case scheme(String, String)
    }

    private static func target(_ arg: String) -> Target? {
        let a = arg.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        switch a {
        case "browser", "web", "http", "https", "links": return .scheme("https", "web links")
        case "mail", "email", "mailto": return .scheme("mailto", "email links")
        default:
            guard !a.isEmpty, let t = UTType(filenameExtension: a) else { return nil }
            return .type(t, ".\(a) files")
        }
    }

    static func results(argument: String) -> [Result] {
        let icon = NSImage(systemSymbolName: "app.badge.checkmark", accessibilityDescription: nil)
        guard let target = target(argument) else {
            return [Result(id: "default:help", title: "Type a file extension or browser, mail",
                           subtitle: "default md · default json · default pdf · default browser", icon: icon, action: .none)]
        }
        let ws = NSWorkspace.shared
        let apps: [URL]
        let current: URL?
        let label: String
        switch target {
        case .type(let t, let l):
            apps = ws.urlsForApplications(toOpen: t); current = ws.urlForApplication(toOpen: t); label = l
        case .scheme(let s, let l):
            let u = URL(string: "\(s)://example.com")!
            apps = ws.urlsForApplications(toOpen: u); current = ws.urlForApplication(toOpen: u); label = l
        }
        // One row per app name, current default first. Copies inside caches and build
        // folders (test browsers, Xcode builds) are left out.
        let home = Paths.home.path
        let normal = apps.filter { u in
            let p = u.path
            return p == current?.path || p.hasPrefix("/Applications/") || p.hasPrefix("/System/Applications/")
                || p.hasPrefix("/System/Library/CoreServices/") || p.hasPrefix(home + "/Applications/")
        }
        var seen = Set<String>()
        let unique = normal.filter { seen.insert($0.deletingPathExtension().lastPathComponent).inserted }
            .sorted { a, b in a == current ? true : b == current ? false : a.lastPathComponent < b.lastPathComponent }
        if unique.isEmpty {
            return [Result(id: "default:none", title: "No app says it opens \(label)", subtitle: nil, icon: icon, action: .none)]
        }
        return unique.prefix(15).map { app in
            let name = app.deletingPathExtension().lastPathComponent
            let isCurrent = app == current
            return Result(id: "default:\(app.path)", title: isCurrent ? "\(name) · opens \(label) now" : "Open \(label) with \(name)",
                          subtitle: app.path.replacingOccurrences(of: Paths.home.path, with: "~"),
                          icon: IconLoader.shared.icon(forPath: app.path),
                          action: isCurrent ? .none : .custom {
                              let done: (Error?) -> Void = { e in Log.write("default \(label) -> \(name): \(e.map { "\($0)" } ?? "ok")") }
                              switch target {
                              case .type(let t, _): ws.setDefaultApplication(at: app, toOpen: t, completion: done)
                              case .scheme(let s, _): ws.setDefaultApplication(at: app, toOpenURLsWithScheme: s, completion: done)
                              }
                          }, revealPath: app.path)
        }
    }
}

extension DefaultApps {
    static var command: KeaCommand {
        KeaCommand(id: "default", name: "Default Apps", keywords: keywords,
                   help: [.init(keyword: "default", summary: "Choose the app that opens a file type, web links or email", example: "default md · default browser")],
                   results: { results(argument: $0.argument) })
    }
}
