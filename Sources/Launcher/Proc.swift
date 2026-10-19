import Foundation

/// Runs a command-line tool and returns its output (stdout and stderr together).
/// Homebrew's folders are added to PATH. Blocks until the tool exits, so call it
/// off the main thread for anything slow.
enum Proc {
    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: String? = nil, extraEnv: [String: String] = [:]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env.merge(extraEnv) { _, new in new }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
