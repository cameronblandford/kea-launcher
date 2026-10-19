import AppKit
import LauncherCore

/// `port 3000` shows what is listening on a port; `kill chrome` finds apps and processes
/// by name. Stopping anything asks first, except a normal Quit of an app (the app itself
/// asks about unsaved work).
enum PortKillCommands {
    static var commands: [KeaCommand] { [port, kill] }

    private static func icon(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }

    /// Asks, then sends SIGTERM (Stop) or SIGKILL (Force Stop).
    private static func confirmStop(_ what: String, pid: Int) {
        let a = NSAlert()
        a.messageText = "Stop \(what)?"
        a.informativeText = "Process \(pid). Stop asks it to exit. Force Stop ends it at once, and unsaved work in it is lost."
        a.addButton(withTitle: "Stop")
        a.addButton(withTitle: "Force Stop")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal()
        guard r != .alertThirdButtonReturn else { return }
        let sig = r == .alertFirstButtonReturn ? SIGTERM : SIGKILL
        let ok = Darwin.kill(pid_t(pid), sig) == 0
        Log.write("kill: \(what) pid \(pid) signal \(sig): \(ok ? "sent" : String(cString: strerror(errno)))")
        if !ok { Notify.post(title: "Could not stop \(what)", body: String(cString: strerror(errno))) }
    }

    // `lsof` takes about half a second. +c 0: whole command names (the default cuts them to 9 characters).
    private static let listeners = Cached { Processes.parseListeners(Proc.run("/usr/sbin/lsof", ["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN"]).output) }
    private static let processes = Cached { Processes.parseProcesses(Proc.run("/bin/ps", ["-x", "-o", "pid=,rss=,comm="]).output) }

    static var port: KeaCommand {
        KeaCommand(id: "port", name: "Ports", keywords: ["port", "ports"],
                   help: [.init(keyword: "port", summary: "What is listening on a port; Return stops it (asks first)", example: "port 3000 · port node · port")],
                   results: { ctx in
                       let arg = ctx.argument.trimmingCharacters(in: .whitespaces).lowercased()
                       guard let all = listeners.get(refresh: ctx.refresh) else {
                           return [Result(id: "port:loading", title: "Reading the ports…", subtitle: "", icon: icon("network"), action: .none)]
                       }
                       let shown = all.filter { l in
                           arg.isEmpty || (Int(arg).map { String(l.port).hasPrefix(String($0)) } ?? l.command.lowercased().contains(arg))
                       }
                       if shown.isEmpty {
                           return [Result(id: "port:none", title: arg.isEmpty ? "Nothing is listening" : "Nothing is listening on \"\(arg)\"",
                                          subtitle: "port alone lists every listening port", icon: icon("network.slash"), action: .none)]
                       }
                       return shown.prefix(40).map { l in
                           let scope = l.address == "*" ? "all interfaces" : "this Mac only (\(l.address))"
                           return Result(id: "port:\(l.port):\(l.pid)", title: ":\(l.port) · \(l.command)",
                                         subtitle: "pid \(l.pid) · \(scope) · Return stops it (asks first)",
                                         icon: icon("network"), action: .custom { confirmStop("\(l.command) on port \(l.port)", pid: l.pid) })
                       }
                   })
    }

    static var kill: KeaCommand {
        KeaCommand(id: "kill", name: "Quit and Kill", keywords: ["kill", "quit"],
                   help: [.init(keyword: "kill", summary: "Quit an app or stop a process by name", example: "kill chrome · kill node")],
                   results: { ctx in
                       let arg = ctx.argument.trimmingCharacters(in: .whitespaces)
                       guard !arg.isEmpty else {
                           return [Result(id: "kill:help", title: "Quit an app or stop a process", subtitle: "kill chrome · kill node · port 3000 for what holds a port",
                                          icon: icon("xmark.octagon"), action: .none)]
                       }
                       var rows: [Result] = []
                       let me = ProcessInfo.processInfo.processIdentifier
                       let words = arg.lowercased().split(separator: " ")
                       let apps = NSWorkspace.shared.runningApplications.filter { app in
                           app.activationPolicy == .regular && app.processIdentifier != me
                               && words.allSatisfy { (app.localizedName ?? "").lowercased().contains($0) }
                       }
                       for app in apps.prefix(6) {
                           let name = app.localizedName ?? "App"
                           let appIcon = app.bundleURL.map { IconLoader.shared.icon(forPath: $0.path) } ?? nil
                           rows.append(Result(id: "kill:quit:\(app.processIdentifier)", title: "Quit \(name)", subtitle: "Asks the app to quit; it may ask about unsaved work",
                                              icon: appIcon, action: .custom { app.terminate() }))
                           rows.append(Result(id: "kill:force:\(app.processIdentifier)", title: "Force Quit \(name)", subtitle: "pid \(app.processIdentifier) · asks first",
                                              icon: appIcon, action: .custom { confirmStop(name, pid: Int(app.processIdentifier)) }))
                       }
                       // Other processes of this user, by name. Apps listed above are left out.
                       let appPIDs = Set(apps.map { Int($0.processIdentifier) })
                       let ps = processes.get(refresh: ctx.refresh)
                       for p in Processes.match(ps ?? [], arg).filter({ !appPIDs.contains($0.pid) && $0.pid != Int(me) && $0.pid > 1 }).prefix(12) {
                           rows.append(Result(id: "kill:proc:\(p.pid)", title: "Stop \(p.name)", subtitle: "pid \(p.pid) · \(Tidy.size(p.memory)) · \(p.path.replacingOccurrences(of: Paths.home.path, with: "~")) · asks first",
                                              icon: icon("gearshape"), action: .custom { confirmStop(p.name, pid: p.pid) }))
                       }
                       if rows.isEmpty, ps == nil {
                           return [Result(id: "kill:loading", title: "Reading the processes…", subtitle: nil, icon: icon("xmark.octagon"), action: .none)]
                       }
                       return rows.isEmpty ? [Result(id: "kill:none", title: "No running app or process matches \"\(arg)\"", subtitle: nil, icon: icon("xmark.octagon"), action: .none)] : rows
                   })
    }
}
