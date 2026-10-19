import Foundation

/// A calendar event as the meeting alerts see it. The app fills it from EventKit.
public struct MeetingEvent: Equatable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendar: String
    public var location: String
    public var notes: String
    public var url: String
    /// The current user said no to the invitation.
    public var declined: Bool
    /// Attendees other than the current user. 0 for an event with no attendee list.
    public var otherAttendees: Int

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, calendar: String = "",
                location: String = "", notes: String = "", url: String = "", declined: Bool = false, otherAttendees: Int = 0) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay
        self.calendar = calendar; self.location = location; self.notes = notes; self.url = url
        self.declined = declined; self.otherAttendees = otherAttendees
    }

    /// One occurrence of an event. A moved event gets a new key, so it alerts again.
    public var key: String { "\(id)@\(Int(start.timeIntervalSince1970))" }

    /// The video call link in the URL field, the location, or the notes, in that order.
    public var joinLink: MeetingLink? {
        MeetingLink.find(in: url) ?? MeetingLink.find(in: location) ?? MeetingLink.find(in: notes)
    }
}

/// A video call link found in event text.
public struct MeetingLink: Equatable {
    public enum Service: String, CaseIterable {
        case zoom = "Zoom", meet = "Google Meet", teams = "Teams", webex = "Webex", facetime = "FaceTime"
    }
    public var service: Service
    public var url: URL

    // Order matters only inside one text: the first link in the text wins, whatever the service.
    private static let patterns: [(Service, String)] = [
        (.zoom, #"zoommtg://[^\s<>"']+"#),
        (.zoom, #"https?://(?:[a-z0-9-]+\.)?zoom(?:gov)?\.us/(?:(?:j|my|w|s|wc/join)/[^\s<>"']+|test\b)"#),
        (.meet, #"https?://meet\.google\.com/[a-z]{3,4}-[a-z]{4}-[a-z]{3,4}[^\s<>"']*"#),
        (.teams, #"https?://teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet)/[^\s<>"']+"#),
        (.webex, #"https?://[a-z0-9-]+\.webex\.com/[^\s<>"']+"#),
        (.facetime, #"https?://facetime\.apple\.com/join[^\s<>"']+"#),
    ]

    /// The link for the app itself, so a Zoom or Teams link skips the browser tab.
    /// The app opens it only when an app handles the scheme; else it opens `url`.
    public var appURL: URL? {
        let s = url.absoluteString
        switch service {
        case .zoom:
            guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme?.hasPrefix("http") == true,
                  let range = c.path.range(of: #"^/j/(\d+)"#, options: .regularExpression) else { return nil }
            let id = c.path[range].dropFirst(3)
            let pwd = c.queryItems?.first { $0.name == "pwd" }?.value
            return URL(string: "zoommtg://\(c.host ?? "zoom.us")/join?action=join&confno=\(id)" + (pwd.map { "&pwd=\($0)" } ?? ""))
        case .teams:
            guard let r = s.range(of: #"^https?://teams\.microsoft\.com/"#, options: .regularExpression) else { return nil }
            return URL(string: "msteams:/" + s[r.upperBound...])
        default:
            return nil
        }
    }

    /// The first video call link in the text, or nil.
    public static func find(in text: String) -> MeetingLink? {
        guard !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        var best: (location: Int, link: MeetingLink)?
        for (service, pattern) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: range), let r = Range(m.range, in: text) else { continue }
            if let b = best, b.location <= m.range.location { continue }
            // Text often wraps a link in brackets or ends a sentence after it.
            var s = String(text[r])
            while let last = s.last, ").,;:]>!?*".contains(last) { s.removeLast() }
            if let url = URL(string: s) { best = (m.range.location, MeetingLink(service: service, url: url)) }
        }
        return best?.link
    }
}

/// The `alerts` section of config, with the parts the planner needs.
public struct MeetingAlertRules: Equatable {
    public var leadMinutes: Double = 1
    public var alertAtStart = false
    public var skipAllDay = true
    public var skipDeclined = true
    public var requireAttendees = false
    /// Calendar titles, matched without case.
    public var ignoreCalendars: [String] = []
    public init() {}
}

/// One alert to show: for one event, at one time.
public struct PlannedAlert: Equatable {
    public enum Kind: String { case before, atStart, snoozed }
    public var event: MeetingEvent
    public var kind: Kind
    public var fireAt: Date
    public var key: String { "\(event.key)#\(kind.rawValue)" }
    public init(event: MeetingEvent, kind: Kind, fireAt: Date) { self.event = event; self.kind = kind; self.fireAt = fireAt }
}

/// What the user did with alerts: which were shown and which events are snoozed.
public struct MeetingAlertState: Equatable {
    /// Alert key to the end of its event, so old keys can be dropped.
    public private(set) var shown: [String: Date] = [:]
    /// Event key to the time the snoozed alert comes back.
    public private(set) var snoozes: [String: Date] = [:]
    public init() {}

    /// The alert was shown (and dismissed, joined, or snoozed). Earlier alerts of the same
    /// event count as shown too, so a late wake shows one alert, not two.
    public mutating func markShown(_ alert: PlannedAlert) {
        shown["\(alert.event.key)#\(PlannedAlert.Kind.before.rawValue)"] = alert.event.end
        if alert.kind != .before { shown["\(alert.event.key)#\(PlannedAlert.Kind.atStart.rawValue)"] = alert.event.end }
        snoozes[alert.event.key] = nil
    }

    /// Dismiss every alert of the event, now and later (also the one at the start).
    public mutating func skip(_ event: MeetingEvent) {
        shown["\(event.key)#\(PlannedAlert.Kind.before.rawValue)"] = event.end
        shown["\(event.key)#\(PlannedAlert.Kind.atStart.rawValue)"] = event.end
        snoozes[event.key] = nil
    }

    public mutating func snooze(_ alert: PlannedAlert, until: Date) {
        markShown(alert)
        snoozes[alert.event.key] = until
    }

    public func wasShown(_ alert: PlannedAlert) -> Bool { shown[alert.key] != nil }

    /// Drops what belongs to events that ended more than a day ago.
    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-86400)
        shown = shown.filter { $0.value > cutoff }
        snoozes = snoozes.filter { $0.value > cutoff }
    }
}

/// Decides which events alert and when. Pure: the app passes the events, the state, and the clock.
public enum MeetingAlertPlanner {
    /// A missed alert (the Mac was asleep) still shows this long after the start.
    public static let lateLimit: TimeInterval = 10 * 60

    public static func eligible(_ e: MeetingEvent, rules: MeetingAlertRules) -> Bool {
        if rules.skipAllDay, e.isAllDay { return false }
        if rules.skipDeclined, e.declined { return false }
        if rules.requireAttendees, e.otherAttendees == 0 { return false }
        let ignored = Set(rules.ignoreCalendars.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        if ignored.contains(e.calendar.lowercased()) { return false }
        return true
    }

    /// Every alert not shown yet, past and future, sorted by time.
    public static func plan(_ events: [MeetingEvent], rules: MeetingAlertRules, state: MeetingAlertState, now: Date) -> [PlannedAlert] {
        var out: [PlannedAlert] = []
        for e in events where eligible(e, rules: rules) && e.end > now {
            if let until = state.snoozes[e.key] {
                out.append(PlannedAlert(event: e, kind: .snoozed, fireAt: until))
                continue
            }
            let lead = max(0, rules.leadMinutes) * 60
            var alerts = [PlannedAlert(event: e, kind: lead > 0 ? .before : .atStart, fireAt: e.start.addingTimeInterval(-lead))]
            if rules.alertAtStart, lead > 0 { alerts.append(PlannedAlert(event: e, kind: .atStart, fireAt: e.start)) }
            out += alerts.filter { !state.wasShown($0) }
        }
        return out.sorted { ($0.fireAt, $0.event.start, $0.event.title) < ($1.fireAt, $1.event.start, $1.event.title) }
    }

    /// The alerts to show now: at most one per event (the latest one due), earliest event first.
    /// A lead alert missed by more than `lateLimit` after the start is dropped; a snooze is not.
    public static func due(_ events: [MeetingEvent], rules: MeetingAlertRules, state: MeetingAlertState, now: Date) -> [PlannedAlert] {
        var latest: [String: PlannedAlert] = [:]
        for a in plan(events, rules: rules, state: state, now: now) where a.fireAt <= now {
            if a.kind != .snoozed, now > a.event.start.addingTimeInterval(lateLimit) { continue }
            latest[a.event.key] = a   // plan is sorted by time, so the last one wins
        }
        return latest.values.sorted { ($0.event.start, $0.event.title) < ($1.event.start, $1.event.title) }
    }

    /// The first alert after `now`, for the scheduler's timer and the `alerts` row.
    public static func next(_ events: [MeetingEvent], rules: MeetingAlertRules, state: MeetingAlertState, now: Date) -> PlannedAlert? {
        plan(events, rules: rules, state: state, now: now).first { $0.fireAt > now }
    }

    /// "in 0:58", "in 4:05", "now", "2m ago": the countdown on the alert.
    public static func countdown(to start: Date, now: Date) -> String {
        let s = Int(start.timeIntervalSince(now).rounded(.up))
        if s > 0 {
            if s < 3600 { return "in \(s / 60):\(String(format: "%02d", s % 60))" }
            return "in \(s / 3600)h \(s % 3600 / 60)m"
        }
        let ago = -s
        if ago < 60 { return "now" }
        if ago < 3600 { return "\(ago / 60)m ago" }
        return "\(ago / 3600)h \(ago % 3600 / 60)m ago"
    }
}
