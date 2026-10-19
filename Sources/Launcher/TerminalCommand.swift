import AppKit
import LauncherCore

/// `t <command>` runs a shell command in a new terminal window (Ghostty by default, config
/// `terminal.app`), in the home folder. The window stays open with the shell, so the output
/// stays readable. `t` alone opens a new window.
enum TerminalCommand {
    static func command(settings: Config.TerminalSettings) -> KeaCommand {
        KeaCommand(id: "terminal", name: "Terminal Command", keywords: [settings.keyword],
                   help: [.init(keyword: settings.keyword, summary: "Run a command in a new terminal window", example: "\(settings.keyword) brew upgrade")],
                   results: { [results(argument: $0.argument, app: settings.app)] })
    }

    private static func results(argument: String, app: String) -> Result {
        let fallback = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else {
            let name = app == TerminalLaunch.ghostty ? "Ghostty" : app
            return Result(id: "terminal:missing", title: "\(name) Is Not Installed",
                          subtitle: "Install it, or set terminal.app in config to com.apple.Terminal",
                          icon: fallback, action: .none)
        }
        let name = FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
        guard TerminalLaunch.supported.contains(app) else {
            return Result(id: "terminal:unsupported", title: "Kea Cannot Run Commands in \(name)",
                          subtitle: "Set terminal.app in config to com.mitchellh.ghostty or com.apple.Terminal",
                          icon: fallback, action: .none)
        }
        let typed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        let action = ResultAction.custom { run(app: app, name: name, command: typed, directory: home) }
        if typed.isEmpty {
            return Result(id: "terminal:open", title: "Open a New \(name) Window",
                          subtitle: "Type a command after the keyword to run it in ~", icon: icon, action: action)
        }
        return Result(id: "terminal:run", title: "Run in \(name)", subtitle: "\(typed.prefix(120)) · in ~, the window stays open",
                      icon: icon, action: action)
    }

    private static func run(app: String, name: String, command: String, directory: String) {
        guard let source = TerminalLaunch.script(app: app, command: command, directory: directory) else { return }
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        // The command text can hold secrets, so the log gets its length only.
        Log.write("terminal: \(name), command of \(command.count) characters: \(error.map { "\($0[NSAppleScript.errorNumber] ?? "?")" } ?? "ok")")
        guard let error else { return }
        if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
            Notify.post(title: "Kea may not control \(name)",
                        body: "Open System Settings > Privacy & Security > Automation > Kea and turn on \(name).")
        } else {
            Notify.post(title: "Could not open \(name)", body: (error[NSAppleScript.errorMessage] as? String) ?? "Unknown error")
        }
    }
}
