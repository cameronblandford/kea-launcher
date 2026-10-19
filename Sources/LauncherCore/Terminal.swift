import Foundation

/// `t <command>`: the AppleScript that opens a terminal window and types the command into
/// its shell. The command goes in as typed input, not as the window's program, so it runs in
/// the user's normal interactive shell (aliases, PATH, history) and the window stays open
/// with that shell after the command ends.
public enum TerminalLaunch {
    public static let ghostty = "com.mitchellh.ghostty"
    public static let appleTerminal = "com.apple.Terminal"
    public static let supported = [ghostty, appleTerminal]

    /// An AppleScript string literal for any text.
    public static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The script for `app` (a bundle id), or nil when Kea does not know how to drive it.
    /// An empty command opens a new window only.
    public static func script(app: String, command: String, directory: String) -> String? {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        switch app {
        case ghostty:
            var lines = [
                "tell application id \(quote(ghostty))",
                "set cfg to new surface configuration",
                "set initial working directory of cfg to \(quote(directory))",
            ]
            if !command.isEmpty { lines.append("set initial input of cfg to \(quote(command)) & return") }
            lines += ["new window with configuration cfg", "activate", "end tell"]
            return lines.joined(separator: "\n")
        case appleTerminal:
            let line = "cd \(shellQuote(directory))" + (command.isEmpty ? "" : " && " + command)
            return ["tell application id \(quote(appleTerminal))", "do script \(quote(line))", "activate", "end tell"]
                .joined(separator: "\n")
        default:
            return nil
        }
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
