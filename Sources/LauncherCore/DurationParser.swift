import Foundation

/// Parses "5m", "5min", "2h5m", "2.5h", "1h 30m", "90s", "45 seconds", "10" (minutes).
/// Returns seconds plus any trailing label.
public enum DurationParser {
    public struct Parsed: Equatable {
        public var seconds: TimeInterval
        public var label: String
    }

    private static let units: [(names: [String], seconds: Double)] = [
        (["h", "hr", "hrs", "hour", "hours"], 3600),
        (["m", "min", "mins", "minute", "minutes"], 60),
        (["s", "sec", "secs", "second", "seconds"], 1),
        (["d", "day", "days"], 86400),
    ]

    public static func parse(_ text: String) -> Parsed? {
        let chars = Array(text.trimmingCharacters(in: .whitespaces))
        var i = 0
        var total = 0.0
        var parts = 0
        var lastUnitless: Double?

        while i < chars.count {
            while i < chars.count, chars[i] == " " { i += 1 }
            let numStart = i
            while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
            guard i > numStart, let value = Double(String(chars[numStart..<i])) else { break }
            let spaced = i < chars.count && chars[i] == " "
            while i < chars.count, chars[i] == " " { i += 1 }
            let unitStart = i
            while i < chars.count, chars[i].isLetter { i += 1 }
            let unit = String(chars[unitStart..<i]).lowercased()
            if unit.isEmpty {
                // A bare number is minutes, but only as the whole duration ("timer 10").
                if parts == 0 { lastUnitless = value; parts += 1 }
                break
            }
            guard let u = units.first(where: { $0.names.contains(unit) }) else {
                // "5 laundry" is five minutes labelled laundry; "5x" is a typo.
                guard spaced else { return nil }
                if parts == 0 { lastUnitless = value; parts += 1 }
                i = unitStart
                break
            }
            total += value * u.seconds
            parts += 1
            lastUnitless = nil
        }

        if let m = lastUnitless { total = m * 60 }
        guard parts > 0, total > 0 else { return nil }
        let label = String(chars[min(i, chars.count)...]).trimmingCharacters(in: .whitespaces)
        return Parsed(seconds: total, label: label)
    }

    /// "1h 05m", "4:32", "12s"
    public static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        if m > 0 { return String(format: "%d:%02d", m, sec) }
        return "\(sec)s"
    }

    /// Compact phrase for confirmations: "5m", "2h30m", "90s", "1h5m10s".
    public static func describe(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        var out = ""
        if s >= 3600 { out += "\(s / 3600)h" }
        if (s % 3600) / 60 > 0 { out += "\((s % 3600) / 60)m" }
        if s % 60 > 0 || out.isEmpty { out += "\(s % 60)s" }
        return out
    }
}
