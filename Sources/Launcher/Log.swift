import Foundation

/// Appends to `~/.launcher/launcher.log`. Also mirrors to NSLog.
enum Log {
    static let url = Paths.root.appendingPathComponent("launcher.log")
    private static let fmt: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()

    static func write(_ message: String) {
        NSLog("launcher: %@", message)
        let line = "\(fmt.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
