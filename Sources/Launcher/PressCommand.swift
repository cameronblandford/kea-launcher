import AppKit
import LauncherCore

/// `press <folder>` frees disk space in a folder and deletes nothing: files get APFS
/// transparent compression, and files with the same content share their data as clones.
/// Each file keeps its name and place and opens as before. The rules and the changes are
/// in core (Press.swift). The first Return only reads the folder; the changes start after
/// a list and a confirmation.
final class PressCommand {
    static let shared = PressCommand()

    private enum State {
        case idle
        case scanning(root: String, since: Date)
        case ready(Press.Plan)
        case working(root: String, done: Int, total: Int, saved: Int64)
        case finished(root: String, Press.Report)
    }

    private var state = State.idle
    /// Set from the main thread, read by the work on its own thread.
    private let stop = Flag()
    private static let log = Paths.root.appendingPathComponent("press-log.csv")
    private static func icon(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }
    private static func short(_ path: String) -> String { path.replacingOccurrences(of: Paths.home.path, with: "~") }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ new: Bool) { lock.lock(); value = new; lock.unlock() }
    }

    private var isLive: Bool {
        switch state {
        case .scanning, .working: return true
        default: return false
        }
    }

    /// The folder that the text names, or the reason that Kea does not press it.
    static func folder(_ text: String) -> (path: String?, problem: String?) {
        let typed = (text.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        let path = URL(fileURLWithPath: typed, relativeTo: Paths.home).standardizedFileURL.resolvingSymlinksInPath().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return (nil, "No folder at \(short(path))") }
        if let reason = Press.refusal(root: path, home: Paths.home.path) { return (nil, reason) }
        var fs = statfs()
        guard statfs(path, &fs) == 0, withUnsafePointer(to: &fs.f_fstypename, { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }) == "apfs" else {
            return (nil, "The folder is not on an APFS disk")
        }
        return (path, nil)
    }

    func results(argument: String) -> [Result] {
        let pressIcon = Self.icon("rectangle.compress.vertical")
        switch state {
        case .scanning(let root, let since):
            return [Result(id: "press:scanning", title: "Reading \(Self.short(root))… \(Int(Date().timeIntervalSince(since))) s", subtitle: "Nothing changes yet · Return stops",
                           icon: pressIcon, action: .custom { [weak self] in self?.stop.set(true) })]
        case .working(let root, let done, let total, let saved):
            return [Result(id: "press:working", title: "Pressing \(Self.short(root)): \(done) of \(total) files, \(Tidy.size(saved)) freed", subtitle: "Return stops after the file in work",
                           icon: pressIcon, action: .custom { [weak self] in self?.stop.set(true) })]
        case .ready(let plan):
            let clear = Result(id: "press:clear", title: "Close this result", subtitle: "Nothing was changed", icon: Self.icon("xmark.circle"), action: .custom { [weak self] in self?.state = .idle })
            guard !plan.isEmpty else {
                return [Result(id: "press:nothing", title: "Nothing to press in \(Self.short(plan.root))", subtitle: Press.describe(plan).replacingOccurrences(of: "\n", with: " · "),
                               icon: pressIcon, action: .custom { [weak self] in self?.state = .idle }, expanded: true)]
            }
            return [Result(id: "press:apply", title: "Press \(Self.short(plan.root)): frees about \(Tidy.size(plan.saving))",
                           subtitle: "Compress \(plan.compress.count) files, share \(plan.shareCount) duplicates · Return shows the list and asks first",
                           icon: pressIcon, action: .custom { [weak self] in self?.confirm(plan) }, revealPath: plan.root), clear]
        case .finished(let root, let report):
            return [Result(id: "press:done", title: "Freed \(Tidy.size(report.saved)) in \(Self.short(root))", subtitle: Press.describe(report).replacingOccurrences(of: "\n", with: " · ") + " · Return closes this",
                           icon: Self.icon("checkmark.circle"), action: .custom { [weak self] in self?.state = .idle }, revealPath: root, expanded: true)]
        case .idle: break
        }
        let term = argument.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else {
            let hint = Result(id: "press:hint", title: "Type a folder to free space in it", subtitle: "For example: press ~/Downloads · files are compressed in place and duplicates share their data · nothing is deleted",
                              icon: pressIcon, action: .none)
            let common = ["Downloads", "Documents", "Desktop", "Developer", "Projects", "p"].map { Paths.home.appendingPathComponent($0).path }.filter { Self.folder($0).path != nil }
            return [hint] + common.map { path in
                Result(id: "press:scan:\(path)", title: "Read \(Self.short(path))", subtitle: "Return reads the folder and shows what a press frees · it changes nothing",
                       icon: IconLoader.shared.icon(forPath: path), action: .custom { [weak self] in self?.scan(path) }, revealPath: path)
            }
        }
        let (path, problem) = Self.folder(term)
        guard let path else { return [Result(id: "press:problem", title: problem ?? "Could not read \(term)", subtitle: "For example: press ~/Downloads", icon: pressIcon, action: .none)] }
        return [Result(id: "press:scan:\(path)", title: "Read \(Self.short(path))", subtitle: "Return reads the folder and shows what a press frees · it changes nothing",
                       icon: IconLoader.shared.icon(forPath: path), action: .custom { [weak self] in self?.scan(path) }, revealPath: path)]
    }

    private func scan(_ root: String) {
        stop.set(false)
        state = .scanning(root: root, since: Date())
        let stop = stop
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let plan = Press.scan(root: root, isCancelled: { stop.isSet })
            DispatchQueue.main.async {
                guard let self else { return }
                if stop.isSet { self.state = .idle; return }
                self.state = .ready(plan)
                Log.write("press: read \(root): \(plan.files) files, compress \(plan.compress.count), share \(plan.shareCount), about \(Tidy.size(plan.saving))")
                Notify.post(title: plan.isEmpty ? "Nothing to press in \(Self.short(root))" : "A press of \(Self.short(root)) frees about \(Tidy.size(plan.saving))", body: "Type press in Kea to continue.")
            }
        }
    }

    private func confirm(_ plan: Press.Plan) {
        let alert = NSAlert()
        alert.messageText = "Press \(Self.short(plan.root))?"
        alert.informativeText = Press.describe(plan) + """


        No file is deleted, moved, or renamed, and each file opens as before. Kea compares each new file with the old one before it takes its place.

        Know this first:
        • A changed file is a new file on the disk, so a backup program copies it again.
        • A program that has a file open does not see the change. Kea leaves files that are open, databases, and files that changed in the last day.
        • There is no button to undo. A compressed file stays compressed until a program writes it again.
        """
        alert.addButton(withTitle: "Press")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        apply(plan)
    }

    private func apply(_ plan: Press.Plan) {
        stop.set(false)
        let total = plan.compress.count + plan.shareCount
        state = .working(root: plan.root, done: 0, total: total, saved: 0)
        let stop = stop
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var done = 0
            var saved: Int64 = 0
            var lines: [String] = []
            let report = Press.apply(plan, isCancelled: { stop.isSet }, onChange: { change in
                done += 1
                if case .saved(let bytes) = change.outcome { saved += bytes }
                lines.append(Self.logLine(change))
                if done % 20 == 0 || done == total {
                    let (d, s) = (done, saved)
                    DispatchQueue.main.async { self?.state = .working(root: plan.root, done: d, total: total, saved: s) }
                }
            })
            Self.appendLog(lines)
            DispatchQueue.main.async {
                self?.state = .finished(root: plan.root, report)
                Log.write("press: \(plan.root): " + Press.describe(report).replacingOccurrences(of: "\n", with: "; "))
                Notify.post(title: "Freed \(Tidy.size(report.saved)) in \(Self.short(plan.root))", body: "Compressed \(report.compressed) files and shared \(report.shared) duplicates.")
            }
        }
    }

    // MARK: - The log of changes

    /// One row for each file that a press looked at: time, action, result, bytes freed, path.
    static func logLine(_ change: Press.Change) -> String {
        let (result, bytes): (String, Int64)
        switch change.outcome {
        case .saved(let freed): (result, bytes) = ("done", freed)
        case .noGain: (result, bytes) = ("no gain", 0)
        case .skipped(let reason): (result, bytes) = ("left alone: \(reason.rawValue)", 0)
        case .failed(let problem): (result, bytes) = ("failed: \(problem)", 0)
        }
        return [ISO8601DateFormatter().string(from: Date()), change.action, result, String(bytes), change.path].map(CSVLog.quote).joined(separator: ",")
    }

    static func appendLog(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.root, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: Data("time,action,result,bytes_freed,path\n".utf8)) }
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    // MARK: - From the shell

    /// `Kea --press-plan <folder>` prints what a press changes. It changes nothing.
    static func printPlan(_ text: String) -> Int32 {
        let (path, problem) = folder(text)
        guard let path else { print(problem ?? "could not read \(text)"); return 1 }
        let start = Date()
        let plan = Press.scan(root: path)
        print(Press.describe(plan))
        print(String(format: "Read in %.1f s. Nothing was changed.", Date().timeIntervalSince(start)))
        for file in plan.compress.prefix(10) { print("compress\t\(Tidy.size(file.allocated))\t\(short(file.path))") }
        for group in plan.groups.prefix(10) { print("share\t\(Tidy.size(group.saving))\t\(short(group.keeper.path)) + \(group.copies.count) copies, first: \(short(group.copies[0].path))") }
        return 0
    }

    /// `Kea --press-apply <folder>` reads the folder and makes the changes, with no question.
    static func runFromShell(_ text: String) -> Int32 {
        let (path, problem) = folder(text)
        guard let path else { print(problem ?? "could not read \(text)"); return 1 }
        let plan = Press.scan(root: path)
        print(Press.describe(plan))
        var lines: [String] = []
        let report = Press.apply(plan, onChange: { lines.append(logLine($0)) })
        appendLog(lines)
        print(Press.describe(report))
        return report.failed.isEmpty ? 0 : 2
    }

    var command: KeaCommand {
        KeaCommand(id: "press", name: "Press a Folder", keywords: ["press"],
                   help: [.init(keyword: "press", summary: "Free disk space in a folder and delete nothing: compress files in place, and let duplicate files share their data", example: "press ~/Downloads")],
                   live: (0.75, { [unowned self] in isLive }),
                   results: { [unowned self] in results(argument: $0.argument) })
    }
}
