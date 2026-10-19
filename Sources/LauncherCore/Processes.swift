import Foundation

/// Reads `lsof` and `ps` output for the `port` and `kill` commands.
public enum Processes {
    public struct Listener: Equatable {
        public var command: String
        public var pid: Int
        public var port: Int
        /// "*" (all interfaces), "127.0.0.1", "[::1]"
        public var address: String
    }

    /// Lines of `lsof -nP -iTCP -sTCP:LISTEN`. One entry per pid and port (IPv4 and IPv6
    /// lines for the same listener are merged; the wider address is kept).
    public static func parseListeners(_ text: String) -> [Listener] {
        var out: [Listener] = []
        for line in text.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 9, let pid = Int(cols[1]), let name = cols.dropLast().last,
                  let colon = name.lastIndex(of: ":"), let port = Int(name[name.index(after: colon)...]) else { continue }
            let address = String(name[..<colon])
            // lsof escapes spaces in command names as \x20.
            let command = cols[0].replacingOccurrences(of: "\\x20", with: " ")
            if let i = out.firstIndex(where: { $0.pid == pid && $0.port == port }) {
                if address == "*" { out[i].address = "*" }
            } else {
                out.append(Listener(command: command, pid: pid, port: port, address: address))
            }
        }
        return out.sorted { $0.port != $1.port ? $0.port < $1.port : $0.pid < $1.pid }
    }

    public struct Process: Equatable {
        public var pid: Int
        /// Resident memory in bytes.
        public var memory: Int64
        public var path: String
        public var name: String { (path as NSString).lastPathComponent }
    }

    /// Lines of `ps -axo pid=,rss=,comm=` (rss is in kilobytes).
    public static func parseProcesses(_ text: String) -> [Process] {
        text.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            let parts = t.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int(parts[0]), let rss = Int64(parts[1]) else { return nil }
            return Process(pid: pid, memory: rss * 1024, path: String(parts[2]).trimmingCharacters(in: .whitespaces))
        }
    }

    /// Processes whose name contains every word of `query`, largest first.
    public static func match(_ all: [Process], _ query: String) -> [Process] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return [] }
        return all.filter { p in words.allSatisfy { p.name.lowercased().contains($0) } }.sorted { $0.memory > $1.memory }
    }
}
