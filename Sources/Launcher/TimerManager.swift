import AppKit
import UserNotifications
import LauncherCore

/// Countdown timers. Fires a notification with sound; the menu bar shows the soonest one.
final class TimerManager {
    struct Entry {
        let id: UUID
        let label: String
        let duration: TimeInterval
        let end: Date
        /// Shown before the countdown in the menu bar, e.g. 🍅.
        var badge = ""
        /// Notification text instead of "5m timer finished".
        var message: String?
        var remaining: TimeInterval { max(0, end.timeIntervalSinceNow) }
        var title: String { label.isEmpty ? "Timer" : label }
    }

    private(set) var timers: [Entry] = []
    private var tick: Timer?
    /// Called every second while timers run, and when the list changes.
    var onChange: (([Entry]) -> Void)?
    /// Called after a timer fires (the Pomodoro chains its next phase here).
    var onFinish: ((Entry) -> Void)?

    /// UNUserNotificationCenter aborts outside an app bundle (the headless --query mode).
    private static let canNotify = Bundle.main.bundleIdentifier != nil

    init() {
        guard Self.canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, err in
            if let err { Log.write("notification auth: \(err)") } else { Log.write("notification auth: \(ok)") }
        }
    }

    @discardableResult
    func start(seconds: TimeInterval, label: String, badge: String = "", message: String? = nil) -> UUID {
        var e = Entry(id: UUID(), label: label, duration: seconds, end: Date().addingTimeInterval(seconds))
        e.badge = badge
        e.message = message
        timers.append(e)
        timers.sort { $0.end < $1.end }
        if tick == nil {
            tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.step() }
        }
        Log.write("timer started: \(DurationParser.describe(seconds)) \(label)")
        onChange?(timers)
        return e.id
    }

    func isRunning(_ id: UUID) -> Bool { timers.contains { $0.id == id } }

    func cancel(_ id: UUID) {
        timers.removeAll { $0.id == id }
        if timers.isEmpty { tick?.invalidate(); tick = nil }
        onChange?(timers)
    }

    private func step() {
        let now = Date()
        let done = timers.filter { $0.end <= now }
        timers.removeAll { $0.end <= now }
        for e in done { fire(e) }
        for e in done { onFinish?(e) }
        if timers.isEmpty { tick?.invalidate(); tick = nil }
        onChange?(timers)
    }

    private func fire(_ e: Entry) {
        NSSound(named: "Glass")?.play()
        Log.write("timer fired: \(e.title)")
        guard Self.canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = e.title
        content.body = e.message ?? "\(DurationParser.describe(e.duration)) timer finished"
        content.sound = .default
        let req = UNNotificationRequest(identifier: e.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err { Log.write("notification failed: \(err)") }
        }
    }

    // MARK: - Results

    func results(argument: String) -> [Result] {
        let icon = IconLoader.shared.icon(forSpec: "sf:timer")
        let arg = argument.trimmingCharacters(in: .whitespaces)
        if arg.isEmpty {
            if timers.isEmpty {
                return [Result(id: "timer:help", title: "Start a timer", subtitle: "timer 5m · timer 2h5m · timer 25m focus", icon: icon, action: .none)]
            }
            return timers.map { e in
                Result(id: "timer:\(e.id)", title: "\(e.title) · \(DurationParser.format(e.remaining)) left",
                       subtitle: "\(DurationParser.describe(e.duration)) timer · fn+Delete cancels", icon: icon, action: .none,
                       onDelete: { [weak self] in self?.cancel(e.id) })
            }
        }
        guard let parsed = DurationParser.parse(arg) else {
            return [Result(id: "timer:bad", title: "Could not read \"\(arg)\"", subtitle: "Try 5m, 90s, 2h5m, 2.5h, or 10 for minutes", icon: icon, action: .none)]
        }
        let name = parsed.label.isEmpty ? "" : " \"\(parsed.label)\""
        let end = Date().addingTimeInterval(parsed.seconds)
        let f = DateFormatter(); f.timeStyle = .short
        return [Result(id: "timer:start", title: "Start a \(DurationParser.describe(parsed.seconds)) timer\(name)",
                       subtitle: "Ends at \(f.string(from: end))", icon: icon,
                       action: .custom { [weak self] in self?.start(seconds: parsed.seconds, label: parsed.label) })]
    }
}

extension TimerManager {
    var command: KeaCommand {
        KeaCommand(id: "timer", name: "Timers", keywords: ["timer"],
                   help: [.init(keyword: "timer", summary: "Countdown with notification", example: "timer 25m focus")],
                   results: { [unowned self] in results(argument: $0.argument) })
    }
}
