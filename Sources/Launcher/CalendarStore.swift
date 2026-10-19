import AppKit
import EventKit
import LauncherCore

/// Creates events in the user's calendar through EventKit and lists upcoming ones.
final class CalendarStore {
    private let store = EKEventStore()
    private let preferredCalendar: String
    private static let canUse = Bundle.main.bundleIdentifier != nil   // EventKit needs a bundle
    var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    init(preferredCalendar: String) {
        self.preferredCalendar = preferredCalendar
        guard Self.canUse else { return }
        Log.write("calendar authorization: \(EKEventStore.authorizationStatus(for: .event).rawValue == 3 ? "full access" : "status \(EKEventStore.authorizationStatus(for: .event).rawValue)")")
        guard !authorized else { return }
        store.requestFullAccessToEvents { ok, err in
            Log.write("calendar access: \(ok) \(err.map { "\($0)" } ?? "")")
        }
    }

    /// Writable calendars, grouped by account, for the settings dropdown.
    static func writableCalendars() -> [(id: String, title: String, source: String)] {
        guard canUse else { return [] }
        let store = EKEventStore()
        return store.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .map { ($0.calendarIdentifier, $0.title, $0.source.title) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    /// The configured calendar by identifier, else by title, else the system default.
    private var calendar: EKCalendar? {
        if !preferredCalendar.isEmpty {
            let all = store.calendars(for: .event)
            if let c = all.first(where: { $0.calendarIdentifier == preferredCalendar }) { return c }
            if let c = all.first(where: { $0.title.caseInsensitiveCompare(preferredCalendar) == .orderedSame }) { return c }
        }
        return store.defaultCalendarForNewEvents
    }

    var calendarName: String { calendar?.title ?? "default calendar" }

    func create(_ p: EventParser.Parsed) {
        guard Self.canUse else { return }
        let e = EKEvent(eventStore: store)
        e.title = p.title
        e.startDate = p.start
        e.endDate = p.end
        e.isAllDay = p.allDay
        e.calendar = calendar
        do {
            try store.save(e, span: .thisEvent, commit: true)
            Log.write("event created: \(p.title) \(p.start)")
            NSSound(named: "Pop")?.play()
        } catch {
            Log.write("event save failed: \(error)")
        }
    }


    func upcoming(days: Int = 7, limit: Int = 12) -> [EKEvent] {
        guard Self.canUse, authorized else { return [] }
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return Array(store.events(matching: pred).sorted { $0.startDate < $1.startDate }.prefix(limit))
    }

    /// Events that overlap the range, in every calendar Kea can read, for the meeting alerts.
    func meetingEvents(from start: Date, to end: Date) -> [MeetingEvent] {
        guard Self.canUse, authorized else { return [] }
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: pred).filter { $0.status != .canceled }.map { e in
            let me = e.attendees?.first { $0.isCurrentUser }
            return MeetingEvent(id: e.calendarItemIdentifier, title: e.title ?? "Untitled", start: e.startDate, end: e.endDate,
                                isAllDay: e.isAllDay, calendar: e.calendar?.title ?? "", location: e.location ?? "",
                                notes: e.notes ?? "", url: e.url?.absoluteString ?? "",
                                declined: me?.participantStatus == .declined,
                                otherAttendees: e.attendees?.filter { !$0.isCurrentUser }.count ?? 0)
        }
    }

    // MARK: - Formatting

    static func span(_ p: EventParser.Parsed) -> String { span(start: p.start, end: p.end, allDay: p.allDay) }

    static func span(start: Date, end: Date, allDay: Bool) -> String {
        let day = DateFormatter(); day.dateFormat = "EEE MMM d"
        let time = DateFormatter(); time.dateFormat = "h:mm a"
        let cal = Calendar.current
        let dayText = cal.isDateInToday(start) ? "Today" : cal.isDateInTomorrow(start) ? "Tomorrow" : day.string(from: start)
        if allDay { return "\(dayText) · all day" }
        let sameDay = cal.isDate(start, inSameDayAs: end)
        let endText = sameDay ? time.string(from: end) : "\(day.string(from: end)) \(time.string(from: end))"
        return "\(dayText), \(time.string(from: start))–\(endText)"
    }

    // MARK: - Results

    func results(argument: String) -> [Result] {
        let icon = IconLoader.shared.icon(forPath: "/System/Applications/Calendar.app")
        let arg = argument.trimmingCharacters(in: .whitespaces)
        if arg.isEmpty {
            let appPath = "/System/Applications/Calendar.app"
            let open = Result(id: "app:\(appPath)", title: "Calendar",
                              subtitle: authorized || !Self.canUse ? "Open Calendar · type an event to add it: cal lunch with sam friday at noon"
                                                                   : "Calendar access not granted yet. Check System Settings › Privacy › Calendars.",
                              icon: icon, action: .openPath(appPath), revealPath: appPath)
            return [open] + upcoming().map { e in
                Result(id: "cal:\(e.eventIdentifier ?? e.title)", title: e.title ?? "Untitled",
                       subtitle: "\(Self.span(start: e.startDate, end: e.endDate, allDay: e.isAllDay)) · \(e.calendar.title)",
                       icon: icon, action: .item(.open("ical://")))
            }
        }
        guard let p = EventParser.parse(arg) else {
            return [Result(id: "cal:nodate", title: arg, subtitle: "No date found. Try: tomorrow at 5p, friday noon, sept 20 10am, next tue 3-4pm",
                           icon: icon, action: .none)]
        }
        return [Result(id: "cal:create", title: p.title, subtitle: "\(Self.span(p)) · \(calendarName) · Return creates",
                       icon: icon, action: .custom { [weak self] in self?.create(p) })]
    }
}

extension CalendarStore {
    func command(keyword: String) -> KeaCommand {
        KeaCommand(id: "calendar", name: "Calendar Events", keywords: [keyword],
                   help: [.init(keyword: keyword, summary: "Create calendar events in plain language", example: "cal dentist fri 2-3:30pm")],
                   results: { [unowned self] in results(argument: $0.argument) })
    }
}
