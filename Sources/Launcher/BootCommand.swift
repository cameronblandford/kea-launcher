import AppKit
import LauncherCore

/// `boot` lists what starts at login or runs in the background, enabled first, and
/// whether it runs now. Return turns an item off where Kea can do that safely:
/// "Open at Login" apps are removed from the list, and your own launch agents
/// (~/Library/LaunchAgents) are stopped and disabled (`launchctl enable` undoes it).
/// Other items (system daemons, items apps register themselves) open Login Items
/// settings, where macOS lets you switch them off.
final class BootCommand {
    static let keywords: Set<String> = ["boot", "startup", "login"]
    private var items: [BootItems.Item] = []
    private var scanning = false
    private var scanned: Date?
    private var turnedOff = Set<String>()
    var isLive: Bool { scanning }

    func scanIfNeeded(force: Bool = false) {
        guard !scanning, force || scanned.map({ Date().timeIntervalSince($0) > 600 }) ?? true else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            // `sfltool dumpbtm` takes about 30 seconds.
            let parsed = BootItems.parse(Proc.run("/usr/bin/sfltool", ["dumpbtm"]).output)
            DispatchQueue.main.async {
                self.items = parsed
                self.scanned = Date()
                self.scanning = false
            }
        }
    }

    private var uid: String { String(getuid()) }

    /// Labels of loaded per-user agents and their PIDs ("-" when loaded but not running).
    private func agentPIDs() -> [String: String] {
        var out: [String: String] = [:]
        for line in Proc.run("/bin/launchctl", ["list"]).output.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t")
            if cols.count == 3 { out[String(cols[2])] = String(cols[0]) }
        }
        return out
    }

    private func isMine(_ i: BootItems.Item) -> Bool {
        i.kind == .agent && (i.url?.hasPrefix(Paths.home.path + "/Library/LaunchAgents/") ?? false)
    }

    func results(argument: String) -> [Result] {
        scanIfNeeded()
        let f = argument.lowercased().trimmingCharacters(in: .whitespaces)
        if items.isEmpty {
            return [Result(id: "boot:scan", title: scanning ? "Reading login and background items…" : "No login or background items found",
                           subtitle: scanning ? "This takes about 30 seconds the first time" : nil,
                           icon: NSImage(systemSymbolName: "power", accessibilityDescription: nil), action: .none)]
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        let pids = agentPIDs()
        let order: [BootItems.Kind] = [.loginApp, .appLoginItem, .agent, .daemon]
        let shown = items.filter { f.isEmpty || $0.name.lowercased().contains(f) || $0.identifier.lowercased().contains(f) }
            .sorted { a, b in
                let ea = a.enabled && !turnedOff.contains(a.identifier), eb = b.enabled && !turnedOff.contains(b.identifier)
                if ea != eb { return ea }
                if a.kind != b.kind { return order.firstIndex(of: a.kind)! < order.firstIndex(of: b.kind)! }
                return a.name.lowercased() < b.name.lowercased()
            }
        var rows = [Result(id: "boot:settings", title: "Open Login Items Settings", subtitle: "Everything here, with macOS's own switches",
                           icon: NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil),
                           action: .openPath("x-apple.systempreferences:com.apple.LoginItems-Settings.extension"))]
        for i in shown {
            let off = !i.enabled || turnedOff.contains(i.identifier)
            let kindText: String
            switch i.kind {
            case .loginApp: kindText = "Opens at login"
            case .appLoginItem: kindText = "Login item of an app"
            case .agent: kindText = isMine(i) ? "Your launch agent" : "Launch agent"
            case .daemon: kindText = "System daemon"
            }
            var state = off ? "off" : "on"
            if i.kind == .loginApp, let u = i.url, running.contains(u) { state += ", running" }
            if i.kind == .agent, let pid = pids[i.identifier] { state += pid == "-" ? ", loaded" : ", running" }
            let action: ResultAction
            var hint = ""
            if off {
                action = .none
            } else if i.identifier == LoginItem.label {
                // Kea's own agent: turning it off here would stop Kea mid-action.
                hint = " · this is Kea; use Launch at Login in its menu"
                action = .none
            } else if i.kind == .loginApp {
                hint = " · Return removes it from login"
                let name = i.url.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") } ?? i.name
                action = .custom { [weak self] in
                    var error: NSDictionary?
                    NSAppleScript(source: "tell application \"System Events\" to delete login item \"\(name.replacingOccurrences(of: "\"", with: ""))\"")?.executeAndReturnError(&error)
                    Log.write("boot: remove login item \(name): \(error.map { "\($0)" } ?? "ok")")
                    if error == nil { self?.turnedOff.insert(i.identifier) }
                }
            } else if isMine(i), let plist = i.url {
                hint = " · Return stops and disables it"
                action = .custom { [weak self, uid] in
                    Proc.run("/bin/launchctl", ["bootout", "gui/\(uid)", plist])
                    let r = Proc.run("/bin/launchctl", ["disable", "gui/\(uid)/\(i.identifier)"])
                    Log.write("boot: disable \(i.identifier): \(r.status)")
                    self?.turnedOff.insert(i.identifier)
                }
            } else {
                hint = " · Return opens Login Items settings"
                action = .openPath("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
            }
            let icon = i.kind == .loginApp ? i.url.map { IconLoader.shared.icon(forPath: $0) } ?? nil
                : NSImage(systemSymbolName: i.kind == .daemon ? "gearshape.2" : "gearshape", accessibilityDescription: nil)
            rows.append(Result(id: "boot:\(i.kind.rawValue):\(i.identifier)", title: "\(i.name) · \(state)",
                               subtitle: kindText + (i.developer.map { " · \($0)" } ?? "") + hint,
                               icon: icon, action: action, revealPath: i.url))
        }
        return rows
    }
}

extension BootCommand {
    var command: KeaCommand {
        KeaCommand(id: "boot", name: "Login Items", keywords: Self.keywords,
                   help: [.init(keyword: "boot", summary: "What starts at login or runs in the background; turn items off", example: "boot · boot postgres")],
                   live: (1, { [unowned self] in isLive }),
                   results: { [unowned self] in results(argument: $0.argument) })
    }
}
