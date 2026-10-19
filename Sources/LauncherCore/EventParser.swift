import Foundation

/// Turns "go to alex's tomorrow at 5p" into a title and a time span, using the system's
/// natural-language date detector plus a normalisation pass for shorthand it misses.
public enum EventParser {
    public struct Parsed: Equatable {
        public var title: String
        public var start: Date
        public var end: Date
        public var allDay: Bool
    }

    static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// Expands shorthand so the detector understands it.
    static func normalize(_ text: String) -> String {
        var s = " " + text + " "
        let rules: [(String, String)] = [
            (#"(?i)\b(\d{1,2}(?::\d{2})?)\s*([ap])\b"#, "$1$2m"),          // 5p -> 5pm, 10:30a -> 10:30am
            (#"(?i)\btmrw\b|\btmr\b|\btomo\b"#, "tomorrow"),
            (#"(?i)\btonite\b"#, "tonight"),
            (#"(?i)\btues\b"#, "tuesday"), (#"(?i)\bthurs\b|\bthur\b"#, "thursday"),
            (#"(?i)\bweds\b"#, "wednesday"),
            (#"(?i)\bnoon\b"#, "12pm"), (#"(?i)\bmidnight\b"#, "12am"),
        ]
        for (pattern, repl) in rules {
            s = s.replacingOccurrences(of: pattern, with: repl, options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// "for 2h", "for 30m", "for 1.5 hours" -> seconds, and the text with it removed.
    static func extractDuration(_ text: String) -> (String, TimeInterval?) {
        let pattern = #"(?i)\bfor\s+(\d+(?:\.\d+)?)\s*(h|hr|hrs|hour|hours|m|min|mins|minute|minutes)\b"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let vr = Range(m.range(at: 1), in: text), let ur = Range(m.range(at: 2), in: text),
              let value = Double(text[vr]) else { return (text, nil) }
        let unit = text[ur].lowercased()
        let seconds = value * (unit.hasPrefix("h") ? 3600 : 60)
        var out = text
        out.removeSubrange(Range(m.range, in: text)!)
        return (out, seconds)
    }

    public static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> Parsed? {
        let normalized = normalize(raw)
        let (text, duration) = extractDuration(normalized)
        guard let detector, let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              var start = match.date, let matchRange = Range(match.range, in: text) else { return nil }

        let matched = text[matchRange].lowercased()
        // The detector defaults to noon when no clock time was given; treat that as all-day.
        let hasClock = matched.range(of: #"\d\s*(am|pm)|\d:\d\d|\b(morning|afternoon|evening|night|tonight)\b"#, options: .regularExpression) != nil
            || matched.contains("12pm") || matched.contains("12am")
        let allDay = !hasClock

        // "at 5pm" on its own means the next 5pm, not one that already passed today.
        // Only for a bare time: an explicit date that has passed stays as typed.
        if start < now, calendar.isDate(start, inSameDayAs: now), !matched.contains("yesterday"), !matched.contains("ago"),
           let bumped = calendar.date(byAdding: .day, value: 1, to: start), !allDay, bumped.timeIntervalSince(now) < 86400 {
            start = bumped
        }

        var end: Date
        if match.duration > 0 { end = start.addingTimeInterval(match.duration) }
        else if let duration { end = start.addingTimeInterval(duration) }
        else if allDay { end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start)) ?? start }
        else { end = start.addingTimeInterval(3600) }
        if allDay { start = calendar.startOfDay(for: start) }

        var title = text
        title.removeSubrange(matchRange)
        title = cleanTitle(title)
        guard !title.isEmpty else { return nil }
        return Parsed(title: title, start: start, end: end, allDay: allDay)
    }

    static func cleanTitle(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Dangling connectors left behind when the date is cut out.
        t = t.replacingOccurrences(of: #"(?i)\s*\b(at|on|from|until|till|to|for|the|in)\s*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)^\s*(at|on|from)\b\s*"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ,.-–"))
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}
