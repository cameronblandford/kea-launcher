import Foundation

/// Tracks how often and how recently a result id was chosen.
public struct Frecency: Codable {
    public struct Entry: Codable, Equatable {
        public var count: Int
        public var last: TimeInterval
    }

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    public init(data: Data) throws {
        entries = try JSONDecoder().decode([String: Entry].self, from: data)
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(entries)
    }

    public mutating func record(_ id: String, now: TimeInterval = Date().timeIntervalSince1970) {
        var e = entries[id] ?? Entry(count: 0, last: 0)
        e.count += 1
        e.last = now
        entries[id] = e
    }

    public func multiplier(for id: String, now: TimeInterval = Date().timeIntervalSince1970) -> Double {
        guard let e = entries[id] else { return 1 }
        var m = 1 + log(1 + Double(e.count))
        let age = now - e.last
        if age < 3600 { m += 0.5 } else if age < 86400 { m += 0.25 }
        return m
    }
}
