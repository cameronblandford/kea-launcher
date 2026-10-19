import AppKit
import LauncherCore

/// Keeps the Mac awake by running /usr/bin/caffeinate. Keywords: caffeinate, awake.
final class Caffeinate {
    static let keywords: Set<String> = ["caff", "caffeinate", "awake", "caffeine"]

    private var process: Process?
    private var until: Date?
    private var timer: Timer?
    /// Called when the state changes (and every minute while active) so the menu bar can reflect it.
    var onChange: ((Bool, Date?) -> Void)?

    var isActive: Bool { process?.isRunning == true }

    func start(seconds: TimeInterval?) {
        stop(notify: false)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -d display, -i idle sleep, -m disk, -s system (on AC); -t timeout in seconds.
        var args = ["-dims"]
        if let s = seconds { args += ["-t", String(Int(s))] }
        p.arguments = args
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.cleared() }
        }
        do {
            try p.run()
            process = p
            until = seconds.map { Date().addingTimeInterval($0) }
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.onChange?(self.isActive, self.until)
            }
            Log.write("caffeinate started \(seconds.map { DurationParser.describe($0) } ?? "indefinitely")")
            onChange?(true, until)
        } catch {
            Log.write("caffeinate failed: \(error)")
        }
    }

    func stop(notify: Bool = true) {
        if let p = process, p.isRunning {
            p.terminationHandler = nil
            p.terminate()
        }
        process = nil
        until = nil
        timer?.invalidate(); timer = nil
        if notify { Log.write("caffeinate stopped"); onChange?(false, nil) }
    }

    private func cleared() {
        process = nil; until = nil
        timer?.invalidate(); timer = nil
        Log.write("caffeinate ended")
        onChange?(false, nil)
    }

    var statusText: String {
        guard isActive else { return "" }
        if let until { return "Awake until \(Self.clock(until))" }
        return "Awake indefinitely"
    }

    private static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: d)
    }

    // MARK: - Lid (pmset disablesleep)

    /// True when macOS is set to stay awake with the lid closed.
    static func lidSleepDisabled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    /// Runs `pmset -a disablesleep N` through the system admin-password dialog, then optionally locks.
    static func setLidSleepDisabled(_ disabled: Bool, thenLock: Bool) {
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        p.terminationHandler = { proc in
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if proc.terminationStatus == 0 {
                Log.write("lid sleep disabled=\(disabled)")
                if thenLock {
                    // Turns the display off; the screen locks if "Require password after sleep" is set.
                    let l = Process(); l.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); l.arguments = ["displaysleepnow"]; try? l.run()
                }
            } else {
                Log.write("pmset disablesleep cancelled or failed: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        try? p.run()
    }

    private func lidResults() -> [Result] {
        let disabled = Self.lidSleepDisabled()
        let lid = IconLoader.shared.icon(forSpec: "sf:laptopcomputer")
        var out: [Result] = [
            Result(id: "lid:status", title: disabled ? "Lid: stays awake when closed" : "Lid: sleeps when closed (normal)",
                   subtitle: disabled ? "Remember to restore normal sleep when done" : "Choose below; macOS asks for your password",
                   icon: IconLoader.shared.icon(forSpec: disabled ? "sf:laptopcomputer.slash" : "sf:laptopcomputer"), action: .none),
        ]
        if !disabled {
            out.append(Result(id: "lid:on", title: "Close lid, stay awake, unlocked", subtitle: "Sets disablesleep 1. Leave it on power with airflow.",
                              icon: lid, action: .custom { Self.setLidSleepDisabled(true, thenLock: false) }))
            out.append(Result(id: "lid:on:lock", title: "Close lid, stay awake, locked", subtitle: "Sets disablesleep 1, then turns the display off so it locks.",
                              icon: IconLoader.shared.icon(forSpec: "sf:lock.laptopcomputer"), action: .custom { Self.setLidSleepDisabled(true, thenLock: true) }))
        } else {
            out.append(Result(id: "lid:lock", title: "Lock now (stay awake)", subtitle: "Turns the display off so it locks; lid setting unchanged.",
                              icon: IconLoader.shared.icon(forSpec: "sf:lock.laptopcomputer"),
                              action: .custom { let l = Process(); l.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); l.arguments = ["displaysleepnow"]; try? l.run() }))
            out.append(Result(id: "lid:off", title: "Restore normal lid sleep", subtitle: "Sets disablesleep 0.",
                              icon: lid, action: .custom { Self.setLidSleepDisabled(false, thenLock: false) }))
        }
        return out
    }

    // MARK: - Results

    func results(argument: String) -> [Result] {
        let icon = IconLoader.shared.icon(forSpec: "sf:cup.and.saucer")
        let arg = argument.trimmingCharacters(in: .whitespaces)
        if arg.lowercased().hasPrefix("lid") { return lidResults() }
        var out: [Result] = []
        if isActive {
            out.append(Result(id: "caf:stop", title: "Active · \(statusText)", subtitle: "Return allows sleep again",
                              icon: IconLoader.shared.icon(forSpec: "sf:cup.and.saucer.fill"), action: .custom { [weak self] in self?.stop() }))
        } else {
            out.append(Result(id: "caf:status", title: "Not active · sleep allowed", subtitle: "Pick a duration below, or type one: caff 45m · caff lid for closed-lid options",
                              icon: IconLoader.shared.icon(forSpec: "sf:moon.zzz"), action: .none))
        }
        if !arg.isEmpty {
            if arg == "off" || arg == "stop" { return [out[0]] }
            if let d = DurationParser.parse(arg) {
                out.insert(Result(id: "caf:custom", title: "Keep awake for \(DurationParser.describe(d.seconds))",
                                  subtitle: "Until \(Self.clock(Date().addingTimeInterval(d.seconds)))" + (isActive ? " · replaces the current session" : ""), icon: icon,
                                  action: .custom { [weak self] in self?.start(seconds: d.seconds) }), at: 0)
                return out
            }
        }
        let presets: [(String, TimeInterval?)] = [("indefinitely", nil), ("30m", 1800), ("1h", 3600), ("2h", 7200), ("4h", 14400), ("8h", 28800)]
        for (label, secs) in presets {
            let title = secs == nil ? "Keep awake indefinitely" : "Keep awake for \(label)"
            let sub = secs.map { "Until \(Self.clock(Date().addingTimeInterval($0)))" } ?? "Until you allow sleep again"
            out.append(Result(id: "caf:\(label)", title: title, subtitle: sub, icon: icon,
                              action: .custom { [weak self] in self?.start(seconds: secs) }))
        }
        if !arg.isEmpty {
            let status = out[0]
            out = out.dropFirst().filter { FuzzyMatcher.score(query: arg, candidate: $0.title) != nil }
            if out.isEmpty { out = [Result(id: "caf:hint", title: "Keep awake", subtitle: "Try: caff 45m, caff 2h, caff off", icon: icon, action: .none)] }
            out.insert(status, at: 0)
        }
        return out
    }
}

extension Caffeinate {
    var command: KeaCommand {
        KeaCommand(id: "caffeinate", name: "Keep Awake", keywords: Self.keywords,
                   help: [.init(keyword: "caff", summary: "Keep the Mac awake; lid options", example: "caff 2h · caff lid")],
                   search: { [unowned self] term, _ in searchRow(term) },
                   results: { [unowned self] in results(argument: $0.argument) })
    }

    /// "Keep Awake" (or "Allow Sleep" while active) in plain search.
    func searchRow(_ term: String) -> [Result] {
        let title = isActive ? "Allow Sleep" : "Keep Awake"
        guard let score = FuzzyMatcher.score(query: term, candidate: title), score > 250 else { return [] }
        return [Result(id: "launcher:awake", title: title,
                       subtitle: isActive ? statusText + " · Return stops" : "caffeinate · pick a duration",
                       icon: IconLoader.shared.icon(forSpec: "sf:cup.and.saucer"),
                       action: isActive ? .custom { [weak self] in self?.stop() } : .none, keyword: "caffeinate awake")]
    }
}
