import Foundation

extension Config {
    /// `autoclicker`: left clicks at the pointer on a timer. It replaces a Hammerspoon
    /// autoclicker, so the defaults are the same (Ctrl+Option+Cmd+C, 0.02 s).
    public struct AutoClick: Codable, Equatable {
        public static let defaultHotkey = "control+option+command+c"
        /// An empty hotkey turns the hotkey off; the keyword still works.
        public var hotkey: String = AutoClick.defaultHotkey
        /// Seconds between clicks. Use `effectiveInterval`, which is clamped.
        public var interval: Double = AutoClickPlan.defaultInterval
        public init() {}
        enum CodingKeys: String, CodingKey { case hotkey, interval }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hotkey = (try? c.decodeIfPresent(String.self, forKey: .hotkey)) ?? AutoClick.defaultHotkey
            interval = (try? c.decodeIfPresent(Double.self, forKey: .interval)) ?? AutoClickPlan.defaultInterval
        }

        public var effectiveInterval: TimeInterval { AutoClickPlan.clamp(interval) }
    }
}

/// The numbers of the autoclicker.
public enum AutoClickPlan {
    public static let defaultInterval: TimeInterval = 0.02
    /// 100 clicks a second. Faster ticks only fill the event queue.
    public static let minInterval: TimeInterval = 0.01
    public static let maxInterval: TimeInterval = 60

    public static func clamp(_ interval: Double) -> TimeInterval {
        guard interval.isFinite else { return defaultInterval }
        return min(max(interval, minInterval), maxInterval)
    }

    /// "50/s" for 0.02 s, "1/s" for 1 s, "0.5/s" for 2 s.
    public static func rate(_ interval: TimeInterval) -> String {
        let perSecond = 1 / clamp(interval)
        if perSecond >= 1 { return "\(Int(perSecond.rounded()))/s" }
        var text = String(format: "%.2f", perSecond)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text)/s"
    }

    /// "control+option+command+c" as "⌃⌥⌘C". Text that is not a hotkey is returned as is.
    public static func hotkeyLabel(_ text: String) -> String {
        guard let spec = try? HotKeySpec.parse(text) else { return text }
        let order: [(HotKeySpec.Modifier, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let mods = order.filter { spec.modifiers.contains($0.0) }.map(\.1).joined()
        let key: String
        switch spec.key {
        case .letter(let c), .digit(let c): key = String(c).uppercased()
        case .space: key = "Space"
        case .return: key = "Return"
        case .escape: key = "Esc"
        case .tab: key = "Tab"
        case .left: key = "←"
        case .right: key = "→"
        case .up: key = "↑"
        case .down: key = "↓"
        case .function(let n): key = "F\(n)"
        }
        return mods + key
    }
}

/// On or off, and what each event does. The app runs the timer and posts the clicks; this
/// decides when, so that every stop path behaves the same way.
public struct AutoClickState: Equatable {
    public enum Event: Equatable {
        /// The hotkey, or Return on the toggle row.
        case toggle
        case start
        /// Return on the stop row.
        case stop
        case escape
        case sleep
        case screenLock
        case quit
    }

    public enum Effect: Equatable {
        case none
        case start
        case stop(reason: String)
        /// Accessibility is missing: ask for it and stay off.
        case needAccess
    }

    public private(set) var isOn = false
    public init() {}

    public mutating func handle(_ event: Event, trusted: Bool) -> Effect {
        switch event {
        case .toggle where isOn, .stop, .escape, .sleep, .screenLock, .quit:
            guard isOn else { return .none }
            isOn = false
            return .stop(reason: Self.reason(event))
        case .toggle, .start:
            guard !isOn else { return .none }
            guard trusted else { return .needAccess }
            isOn = true
            return .start
        }
    }

    private static func reason(_ event: Event) -> String {
        switch event {
        case .toggle: return "hotkey"
        case .stop: return "command"
        case .escape: return "escape"
        case .sleep: return "sleep"
        case .screenLock: return "screen lock"
        case .quit: return "quit"
        case .start: return "start"
        }
    }
}
