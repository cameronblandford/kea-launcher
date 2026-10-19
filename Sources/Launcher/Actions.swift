import AppKit
import LauncherCore

enum Actions {
    static func perform(_ action: ResultAction, scripts: ScriptCommands) {
        switch action {
        case .openPath(let path):
            open(path)
        case .item(let item):
            switch item {
            case .open(let target): open(target)
            case .shell(let cmd): shell(cmd)
            case .copy(let text):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case .runScript(let url, let arg):
            scripts.fire(url, argument: arg)
        case .custom(let block):
            block()
        case .fill:
            break   // handled by the panel
        case .openWith(let url, let appPath):
            Log.write("open \(url) with \(appPath)")
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: appPath), configuration: NSWorkspace.OpenConfiguration())
        case .none:
            break
        }
    }

    /// Moves a file to the Trash. Reversible from Finder.
    static func trash(_ path: String) {
        let url = URL(fileURLWithPath: path)
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        catch { Log.write("trash failed for \(path): \(error)") }
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private static func open(_ target: String) {
        Log.write("open: \(target)")
        let expanded = Paths.expand(target)
        if expanded.hasPrefix("/") {
            let url = URL(fileURLWithPath: expanded)
            if url.pathExtension == "app" {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
            }
        } else if let url = URL(string: target) {
            openScheme(url)
        }
    }

    /// Custom-scheme links (obsidian://, dict://) get lost when the handling app is still
    /// launching: Obsidian's start-up flow opens its home page over the link. So if the
    /// handler is not running yet, launch it, wait for it to finish, then send the link.
    private static func openScheme(_ url: URL) {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
              let bundleID = Bundle(url: appURL)?.bundleIdentifier else {
            NSWorkspace.shared.open(url)
            return
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.contains(where: { $0.isFinishedLaunching }) {
            NSWorkspace.shared.open(url)
            return
        }
        Log.write("launching \(bundleID) before opening \(url.scheme ?? "") link")
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { app, error in
            guard let app, error == nil else {
                Log.write("launch failed: \(String(describing: error))")
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                return
            }
            waitUntilLaunched(app, deadline: Date().addingTimeInterval(20)) {
                // Give start-up plugins a moment to open their own tabs first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSWorkspace.shared.open(url) }
            }
        }
    }

    private static func waitUntilLaunched(_ app: NSRunningApplication, deadline: Date, then: @escaping () -> Void) {
        if app.isFinishedLaunching || Date() > deadline { DispatchQueue.main.async(execute: then); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waitUntilLaunched(app, deadline: deadline, then: then) }
    }

    private static func shell(_ command: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        try? p.run()
    }
}
