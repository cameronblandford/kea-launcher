import AppKit
import LauncherCore

struct ScriptCommand {
    var name: String
    var manifest: CommandManifest
    var runURL: URL

    var icon: NSImage {
        IconLoader.shared.icon(forSpec: manifest.icon) ?? IconLoader.shared.terminalIcon
    }
}

/// Loads `~/.launcher/commands/*/command.json` and runs their `run` scripts.
final class ScriptCommands {
    private(set) var commands: [ScriptCommand] = []
    private let processQueue = DispatchQueue(label: "launcher.scripts", qos: .userInitiated)

    func reload() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.commands, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            commands = []
            return
        }
        commands = dirs.compactMap { dir in
            let manifestURL = dir.appendingPathComponent("command.json")
            let runURL = dir.appendingPathComponent("run")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? CommandManifest.decode(data),
                  fm.isExecutableFile(atPath: runURL.path) else {
                if fm.fileExists(atPath: manifestURL.path) {
                    Log.write("skipping command at \(dir.lastPathComponent): bad command.json or run not executable")
                }
                return nil
            }
            return ScriptCommand(name: dir.lastPathComponent, manifest: manifest, runURL: runURL)
        }.sorted { $0.manifest.title < $1.manifest.title }
    }

    var listKeywords: Set<String> {
        Set(commands.filter { $0.manifest.mode == .list }.map { $0.manifest.keyword })
    }

    func command(forKeyword kw: String) -> ScriptCommand? {
        commands.first { $0.manifest.keyword == kw }
    }

    func command(forID id: String) -> ScriptCommand? {
        guard id.hasPrefix("cmd:") else { return nil }
        let name = String(id.dropFirst(4))
        return commands.first { $0.name == name }
    }

    /// Results for commands that match a free-text search. Action commands run with the whole query;
    /// list commands open themselves (the user then types the keyword and a space).
    func results(for query: String, frecency: Frecency) -> [Result] {
        let rankables = commands.map { Rankable(id: "cmd:\($0.name)", text: $0.manifest.title, secondary: $0.manifest.keyword) }
        let byID = Dictionary(uniqueKeysWithValues: commands.map { ("cmd:\($0.name)", $0) })
        return Ranker.rank(rankables, query: query, frecency: frecency).compactMap { r in
            guard let c = byID[r.id] else { return nil }
            let action: ResultAction = c.manifest.mode == .action ? .runScript(c.runURL, argument: "") : .none
            return Result(id: r.id, title: c.manifest.title, subtitle: c.manifest.subtitle ?? c.manifest.keyword,
                          icon: c.icon, action: action, keyword: c.manifest.keyword)
        }
    }

    /// Runs a list command with the given argument and returns its items.
    func run(_ command: ScriptCommand, argument: String, completion: @escaping ([Result]) -> Void) {
        processQueue.async {
            let (data, err, ok) = self.execute(command.runURL, arguments: [argument])
            var results: [Result] = []
            if ok, let out = try? ScriptOutput.decode(data) {
                results = out.items.enumerated().map { i, item in
                    Result(id: "cmd:\(command.name):\(item.title)", title: item.title, subtitle: item.subtitle,
                           icon: IconLoader.shared.icon(forSpec: item.icon) ?? command.icon,
                           action: item.action.map { .item($0) } ?? .none,
                           revealPath: Self.revealPath(for: item.action))
                }
            } else {
                let firstErr = err.split(separator: "\n").first.map(String.init) ?? "no output"
                results = [Result(id: "cmd:\(command.name):error", title: "\(command.manifest.title) failed",
                                  subtitle: firstErr, icon: IconLoader.shared.icon(forSpec: "sf:exclamationmark.triangle"), action: .none)]
            }
            DispatchQueue.main.async { completion(results) }
        }
    }

    /// Runs an action command in the background. Errors go to the log.
    func fire(_ runURL: URL, argument: String) {
        processQueue.async {
            let (_, err, ok) = self.execute(runURL, arguments: [argument])
            if !ok { Log.write("\(runURL.path) failed: \(err)") }
        }
    }

    private static func revealPath(for action: ItemAction?) -> String? {
        if case .open(let target) = action, target.hasPrefix("/") || target.hasPrefix("~") { return Paths.expand(target) }
        return nil
    }

    private func execute(_ url: URL, arguments: [String]) -> (Data, String, Bool) {
        let p = Process()
        p.executableURL = url
        p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        p.currentDirectoryURL = Paths.home
        let out = Pipe(), errPipe = Pipe()
        p.standardOutput = out
        p.standardError = errPipe
        do { try p.run() } catch { return (Data(), "\(error)", false) }
        let deadline = DispatchTime.now() + 8
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { p.waitUntilExit(); group.leave() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        if group.wait(timeout: deadline) == .timedOut {
            p.terminate()
            return (Data(), "timed out", false)
        }
        return (data, String(data: errData, encoding: .utf8) ?? "", p.terminationStatus == 0)
    }
}
