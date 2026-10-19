import CoreGraphics
import Foundation

/// Text expansion: type a trigger such as `;td` anywhere and it becomes its text.
public enum Snippets {
    /// The starting set: the three date triggers from a Hammerspoon expander.
    public static let defaults: [String: String] = [";td": "{date}", ";tm": "{date+1}", ";yd": "{date-1}"]

    /// Fills `{date}`, `{date+3}`, `{date-1}`, `{time}`, `{datetime}` and `{clipboard}`.
    public static func expand(_ template: String, now: Date = Date(), calendar: Calendar = .current, clipboard: String = "") -> String {
        var out = ""
        var rest = Substring(template)
        func date(_ offset: Int) -> String {
            let d = calendar.date(byAdding: .day, value: offset, to: now) ?? now
            let c = calendar.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
        func time() -> String {
            let c = calendar.dateComponents([.hour, .minute], from: now)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += rest[..<open]
            let name = rest[rest.index(after: open)..<close].lowercased()
            var filled: String?
            switch name {
            case "date": filled = date(0)
            case "time": filled = time()
            case "datetime": filled = date(0) + " " + time()
            case "clipboard": filled = clipboard
            case _ where name.hasPrefix("date+") || name.hasPrefix("date-"): filled = Int(name.dropFirst(4)).map(date)
            default: break
            }
            if let filled {
                out += filled
                rest = rest[rest.index(after: close)...]
            } else {
                // Not a placeholder: keep the brace as typed, and look again after it
                // (`{ "d": "{date}" }` still fills the date).
                out += "{"
                rest = rest[rest.index(after: open)...]
            }
        }
        return out + rest
    }

    /// The last characters typed, to spot a trigger. Kept only in memory, and only as
    /// long as the longest trigger.
    public struct Buffer {
        private var text = ""
        private let triggers: [String]
        private let maxLength: Int

        public init(triggers: [String]) {
            self.triggers = triggers.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
            maxLength = self.triggers.map(\.count).max() ?? 0
        }

        /// Adds typed characters. Returns the trigger that the text now ends with (the
        /// longest one), and forgets the text so it cannot fire twice.
        public mutating func type(_ chars: String) -> String? {
            guard maxLength > 0 else { return nil }
            text += chars
            if text.count > maxLength { text = String(text.suffix(maxLength)) }
            guard let hit = triggers.first(where: { text.hasSuffix($0) }) else { return nil }
            text = ""
            return hit
        }

        public mutating func backspace() { if !text.isEmpty { text.removeLast() } }

        /// Call when the caret moved or focus changed (arrows, Return, a click, a shortcut).
        public mutating func reset() { text = "" }
    }

    /// `new ;sig Best, Sam` → (";sig", "Best, Sam"). The trigger is the first word.
    public static func parseNew(_ text: String) -> (trigger: String, expansion: String)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let space = t.firstIndex(of: " ") else { return nil }
        let trigger = String(t[..<space])
        let expansion = t[t.index(after: space)...].trimmingCharacters(in: .whitespaces)
        guard trigger.count >= 2, !expansion.isEmpty else { return nil }
        return (trigger, expansion)
    }
}

/// `layout`: where each app's window sits, as shares of its display, so a saved layout
/// fits a display of another size.
public enum WindowLayouts {
    public struct Placement: Codable, Equatable {
        public var bundleID: String
        public var app: String
        /// The display's name when saved; a display with this name gets the window back.
        public var display: String
        /// x, y, width, height as shares (0...1) of that display's usable area.
        public var frame: [Double]

        public init(bundleID: String, app: String, display: String, frame: [Double]) {
            self.bundleID = bundleID; self.app = app; self.display = display; self.frame = frame
        }
    }

    public static func fractions(of window: CGRect, in area: CGRect) -> [Double] {
        guard area.width > 0, area.height > 0 else { return [0, 0, 1, 1] }
        func r(_ v: CGFloat) -> Double { (Double(v) * 10000).rounded() / 10000 }
        return [r((window.minX - area.minX) / area.width), r((window.minY - area.minY) / area.height),
                r(window.width / area.width), r(window.height / area.height)]
    }

    public static func rect(_ f: [Double], in area: CGRect) -> CGRect {
        guard f.count == 4 else { return area }
        return CGRect(x: area.minX + CGFloat(f[0]) * area.width, y: area.minY + CGFloat(f[1]) * area.height,
                      width: CGFloat(f[2]) * area.width, height: CGFloat(f[3]) * area.height).integral
    }

    /// The display a window is mostly on.
    public static func displayIndex(for window: CGRect, areas: [CGRect]) -> Int? {
        func overlap(_ a: CGRect) -> CGFloat { let i = a.intersection(window); return i.isNull ? 0 : i.width * i.height }
        guard let best = areas.indices.max(by: { overlap(areas[$0]) < overlap(areas[$1]) }), overlap(areas[best]) > 0 else { return nil }
        return best
    }
}
