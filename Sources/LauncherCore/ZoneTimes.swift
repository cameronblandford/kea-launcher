import Foundation

/// `3pm pst in nyc`, `15:30 london to tokyo`, `time in tokyo`, `tokyo time`.
public enum ZoneTimes {
    /// Abbreviations and nicknames people type, mapped to time zone identifiers.
    static let names: [String: String] = [
        "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles", "pt": "America/Los_Angeles", "la": "America/Los_Angeles", "sf": "America/Los_Angeles",
        "seattle": "America/Los_Angeles", "california": "America/Los_Angeles",
        "mst": "America/Denver", "mdt": "America/Denver", "mt": "America/Denver",
        "cst": "America/Chicago", "cdt": "America/Chicago", "ct": "America/Chicago", "austin": "America/Chicago", "texas": "America/Chicago",
        "est": "America/New_York", "edt": "America/New_York", "et": "America/New_York", "nyc": "America/New_York", "ny": "America/New_York",
        "boston": "America/New_York", "dc": "America/New_York", "miami": "America/New_York",
        "utc": "UTC", "gmt": "UTC", "z": "UTC",
        "bst": "Europe/London", "uk": "Europe/London", "cet": "Europe/Paris", "cest": "Europe/Paris", "eet": "Europe/Athens",
        "ist": "Asia/Kolkata", "india": "Asia/Kolkata", "jst": "Asia/Tokyo", "japan": "Asia/Tokyo", "kst": "Asia/Seoul",
        "sgt": "Asia/Singapore", "hkt": "Asia/Hong_Kong", "aest": "Australia/Sydney", "aedt": "Australia/Sydney", "nzst": "Pacific/Auckland",
        "nz": "Pacific/Auckland", "hawaii": "Pacific/Honolulu", "hst": "Pacific/Honolulu", "beijing": "Asia/Shanghai", "china": "Asia/Shanghai",
        "here": "", "local": "", "me": "",
    ]

    /// A zone for a word: a nickname above, or a city in the system's zone list ("tokyo", "new york", "sao paulo").
    public static func zone(_ word: String, local: TimeZone = .current) -> TimeZone? {
        let w = word.lowercased().trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return nil }
        if let id = names[w] { return id.isEmpty ? local : TimeZone(identifier: id) }
        let key = w.replacingOccurrences(of: " ", with: "_")
        if let id = TimeZone.knownTimeZoneIdentifiers.first(where: { $0.lowercased().split(separator: "/").last.map(String.init) == key }) {
            return TimeZone(identifier: id)
        }
        return nil
    }

    public struct Answer: Equatable {
        /// "6:00 PM"
        public var time: String
        /// "New York" or "PST"
        public var place: String
        /// "tomorrow", "yesterday" or "" compared with the source day.
        public var dayNote: String
        /// "3:00 PM in Los Angeles" or "now"
        public var source: String
    }

    static func label(_ word: String, _ tz: TimeZone) -> String {
        if word.count <= 4, names[word.lowercased()] != nil { return word.uppercased() }
        return tz.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? tz.identifier
    }

    /// "3pm", "3:30pm", "15:30", "3 pm", "noon", "midnight" as hour and minute.
    static func clock(_ text: String) -> (h: Int, m: Int)? {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "")
        if t == "noon" { return (12, 0) }
        if t == "midnight" { return (0, 0) }
        guard let r = t.range(of: #"^(\d{1,2})(:(\d{2}))?(am|pm|a|p)?$"#, options: .regularExpression), r == t.startIndex..<t.endIndex else { return nil }
        let digits = t.prefix { $0.isNumber }
        guard var h = Int(digits) else { return nil }
        var m = 0
        if let colon = t.firstIndex(of: ":") { m = Int(t[t.index(after: colon)...].prefix(2)) ?? 0 }
        let pm = t.hasSuffix("pm") || t.hasSuffix("p"), am = t.hasSuffix("am") || t.hasSuffix("a")
        guard (pm || am) ? (1...12).contains(h) : (0...23).contains(h), (0...59).contains(m) else { return nil }
        // A bare number with no colon and no am/pm ("3") is not clearly a time.
        if !pm, !am, !t.contains(":") { return nil }
        if pm, h < 12 { h += 12 }
        if am, h == 12 { h = 0 }
        return (h, m)
    }

    public static func convert(_ text: String, now: Date = Date(), local: TimeZone = .current) -> Answer? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        func format(_ date: Date, _ tz: TimeZone) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = tz
            f.dateFormat = "h:mm a"
            return f.string(from: date)
        }
        func note(_ date: Date, from: TimeZone, to: TimeZone) -> String {
            var a = Calendar(identifier: .gregorian), b = Calendar(identifier: .gregorian)
            a.timeZone = from; b.timeZone = to
            let da = a.dateComponents([.year, .month, .day], from: date), db = b.dateComponents([.year, .month, .day], from: date)
            guard let x = Calendar(identifier: .gregorian).date(from: da), let y = Calendar(identifier: .gregorian).date(from: db) else { return "" }
            return y > x ? "tomorrow" : y < x ? "yesterday" : ""
        }
        // "time in tokyo", "now in tokyo", "tokyo time"
        for (prefix, suffix) in [("time in ", ""), ("now in ", ""), ("time ", ""), ("", " time"), ("", " now")] {
            if t.hasPrefix(prefix), t.hasSuffix(suffix), t.count > prefix.count + suffix.count {
                let word = String(t.dropFirst(prefix.count).dropLast(suffix.count))
                if let tz = zone(word, local: local) {
                    return Answer(time: format(now, tz), place: label(word, tz), dayNote: note(now, from: local, to: tz), source: "now")
                }
            }
        }
        // "<clock> [zone] in|to <zone>"
        for sep in [" in ", " to "] {
            guard let r = t.range(of: sep, options: .backwards) else { continue }
            let left = String(t[..<r.lowerBound]), right = String(t[r.upperBound...])
            guard let target = zone(right, local: local) else { continue }
            // The clock is the first word or two; the rest names the source zone (default: here).
            let words = left.split(separator: " ").map(String.init)
            for take in [2, 1] where words.count >= take {
                guard let c = clock(words.prefix(take).joined()) else { continue }
                let srcWord = words.dropFirst(take).joined(separator: " ")
                guard let src = srcWord.isEmpty ? local : zone(srcWord, local: local) else { continue }
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = src
                var comps = cal.dateComponents([.year, .month, .day], from: now)
                comps.hour = c.h; comps.minute = c.m
                guard let date = cal.date(from: comps) else { continue }
                return Answer(time: format(date, target), place: label(right, target), dayNote: note(date, from: src, to: target),
                              source: "\(format(date, src)) in \(srcWord.isEmpty ? "your time" : label(srcWord, src))")
            }
        }
        return nil
    }
}
