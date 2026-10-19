import Foundation

/// One row per `log <category> <value>`: timestamp, category, value.
public enum CSVLog {
    public static let header = "date,category,value"

    public struct Entry: Equatable {
        public var date: String
        public var category: String
        public var value: String
        public init(date: String, category: String, value: String) {
            self.date = date; self.category = category; self.value = value
        }
    }

    /// "food banana split" -> (food, "banana split"). Nil without both parts.
    public static func parse(_ text: String) -> (category: String, value: String)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let space = t.firstIndex(of: " ") else { return nil }
        let cat = String(t[..<space]).lowercased()
        let value = t[t.index(after: space)...].trimmingCharacters(in: .whitespaces)
        guard !cat.isEmpty, !value.isEmpty else { return nil }
        return (cat, value)
    }

    public static func quote(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    public static func line(_ e: Entry) -> String {
        [e.date, e.category, e.value].map(quote).joined(separator: ",")
    }

    /// Parses one CSV line with quoted fields.
    public static func parseLine(_ line: String) -> Entry? {
        let fields = self.fields(line)
        guard fields.count >= 3 else { return nil }
        return Entry(date: fields[0], category: fields[1], value: fields[2...].joined(separator: ","))
    }

    /// The fields of one CSV line, with quotes removed.
    public static func fields(_ line: String) -> [String] {
        var fields: [String] = []
        var cur = ""
        var inQuotes = false
        var it = line.makeIterator()
        while let c = it.next() {
            if inQuotes {
                if c == "\"" {
                    // Doubled quote inside a quoted field.
                    var copy = it
                    if copy.next() == "\"" { cur.append("\""); it = copy } else { inQuotes = false }
                } else { cur.append(c) }
            } else if c == "\"" { inQuotes = true }
            else if c == "," { fields.append(cur); cur = "" }
            else { cur.append(c) }
        }
        fields.append(cur)
        return fields
    }

    /// ISO 8601 with the time-zone offset: "2026-10-03T14:05:12-04:00".
    public static func timestamp(_ date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return f.string(from: date)
    }

    /// A stamp for reading: "2026-10-03 14:05". Works for stamps with or without an
    /// offset (rows written before the offset was added have none).
    public static func display(_ stamp: String) -> String {
        guard stamp.count >= 16, stamp.dropFirst(10).first == "T" else { return stamp }
        return String(stamp.prefix(10)) + " " + String(stamp.dropFirst(11).prefix(5))
    }
}
