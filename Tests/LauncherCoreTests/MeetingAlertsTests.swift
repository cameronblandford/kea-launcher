import XCTest
@testable import LauncherCore

final class MeetingAlertsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ id: String = "e1", startIn minutes: Double = 10, length: Double = 30, allDay: Bool = false,
               calendar: String = "Work", declined: Bool = false, attendees: Int = 2) -> MeetingEvent {
        let start = t0.addingTimeInterval(minutes * 60)
        return MeetingEvent(id: id, title: "Meeting \(id)", start: start, end: start.addingTimeInterval(length * 60), isAllDay: allDay,
                            calendar: calendar, declined: declined, otherAttendees: attendees)
    }

    // MARK: Links

    func testFindsEachService() {
        let cases: [(String, MeetingLink.Service, String)] = [
            ("Join: https://us02web.zoom.us/j/8123456789?pwd=abc.", .zoom, "https://us02web.zoom.us/j/8123456789?pwd=abc"),
            ("https://zoom.us/my/sam", .zoom, "https://zoom.us/my/sam"),
            ("<https://meet.google.com/abc-defg-hij>", .meet, "https://meet.google.com/abc-defg-hij"),
            ("Teams https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=y", .teams,
             "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=y"),
            ("(https://acme.webex.com/acme/j.php?MTID=m123)", .webex, "https://acme.webex.com/acme/j.php?MTID=m123"),
            ("https://facetime.apple.com/join#v=1&p=AbC&k=xyz", .facetime, "https://facetime.apple.com/join#v=1&p=AbC&k=xyz"),
            ("Zoom test page https://zoom.us/test", .zoom, "https://zoom.us/test"),
            ("zoommtg://zoom.us/join?confno=123", .zoom, "zoommtg://zoom.us/join?confno=123"),
        ]
        for (text, service, url) in cases {
            let link = MeetingLink.find(in: text)
            XCTAssertEqual(link?.service, service, text)
            XCTAssertEqual(link?.url.absoluteString, url, text)
        }
    }

    func testNoLinkInPlainText() {
        XCTAssertNil(MeetingLink.find(in: ""))
        XCTAssertNil(MeetingLink.find(in: "Room 4B, https://example.com/agenda"))
        XCTAssertNil(MeetingLink.find(in: "https://zoom.us/pricing"), "a Zoom page that is not a meeting")
    }

    func testAppURL() {
        XCTAssertEqual(MeetingLink.find(in: "https://us02web.zoom.us/j/8123456789?pwd=abc")?.appURL?.absoluteString,
                       "zoommtg://us02web.zoom.us/join?action=join&confno=8123456789&pwd=abc")
        XCTAssertNil(MeetingLink.find(in: "https://zoom.us/my/sam")?.appURL, "a personal room link opens in the browser")
        XCTAssertEqual(MeetingLink.find(in: "https://teams.microsoft.com/l/meetup-join/19%3ax/0")?.appURL?.absoluteString,
                       "msteams:/l/meetup-join/19%3ax/0")
        XCTAssertNil(MeetingLink.find(in: "https://meet.google.com/abc-defg-hij")?.appURL)
    }

    func testFirstLinkInTextWins() {
        let text = "Backup: https://meet.google.com/abc-defg-hij main https://zoom.us/j/1"
        XCTAssertEqual(MeetingLink.find(in: text)?.service, .meet)
    }

    func testEventLinkOrderIsURLThenLocationThenNotes() {
        var e = event()
        e.notes = "https://zoom.us/j/3"
        XCTAssertEqual(e.joinLink?.url.absoluteString, "https://zoom.us/j/3")
        e.location = "https://meet.google.com/abc-defg-hij"
        XCTAssertEqual(e.joinLink?.service, .meet)
        e.url = "https://teams.live.com/meet/9"
        XCTAssertEqual(e.joinLink?.service, .teams)
    }

    // MARK: Planner

    func testLeadAlert() {
        let rules = MeetingAlertRules()
        let e = event(startIn: 10)
        let plan = MeetingAlertPlanner.plan([e], rules: rules, state: .init(), now: t0)
        XCTAssertEqual(plan.map(\.kind), [.before])
        XCTAssertEqual(plan.first?.fireAt, e.start.addingTimeInterval(-60))
        XCTAssertEqual(MeetingAlertPlanner.due([e], rules: rules, state: .init(), now: t0), [])
        XCTAssertEqual(MeetingAlertPlanner.due([e], rules: rules, state: .init(), now: e.start.addingTimeInterval(-60)).map(\.kind), [.before])
    }

    func testAlertAtStartAddsSecondAlert() {
        var rules = MeetingAlertRules()
        rules.alertAtStart = true
        rules.leadMinutes = 5
        let e = event(startIn: 10)
        XCTAssertEqual(MeetingAlertPlanner.plan([e], rules: rules, state: .init(), now: t0).map(\.kind), [.before, .atStart])
        var state = MeetingAlertState()
        let first = MeetingAlertPlanner.due([e], rules: rules, state: state, now: e.start.addingTimeInterval(-300))
        XCTAssertEqual(first.map(\.kind), [.before])
        state.markShown(first[0])
        XCTAssertEqual(MeetingAlertPlanner.due([e], rules: rules, state: state, now: e.start.addingTimeInterval(-60)), [])
        XCTAssertEqual(MeetingAlertPlanner.due([e], rules: rules, state: state, now: e.start).map(\.kind), [.atStart])
    }

    func testZeroLeadIsOneAlertAtStart() {
        var rules = MeetingAlertRules()
        rules.leadMinutes = 0
        rules.alertAtStart = true
        XCTAssertEqual(MeetingAlertPlanner.plan([event()], rules: rules, state: .init(), now: t0).map(\.kind), [.atStart])
    }

    func testLateWakeShowsOneAlert() {
        var rules = MeetingAlertRules()
        rules.alertAtStart = true
        let e = event(startIn: 10)
        var state = MeetingAlertState()
        let due = MeetingAlertPlanner.due([e], rules: rules, state: state, now: e.start.addingTimeInterval(120))
        XCTAssertEqual(due.map(\.kind), [.atStart], "both alerts are due; only the latest shows")
        state.markShown(due[0])
        XCTAssertEqual(MeetingAlertPlanner.due([e], rules: rules, state: state, now: e.start.addingTimeInterval(130)), [])
    }

    func testTooLateOrEndedIsDropped() {
        let e = event(startIn: 10, length: 60)
        XCTAssertEqual(MeetingAlertPlanner.due([e], rules: .init(), state: .init(), now: e.start.addingTimeInterval(11 * 60)), [])
        XCTAssertEqual(MeetingAlertPlanner.plan([e], rules: .init(), state: .init(), now: e.end.addingTimeInterval(1)), [])
    }

    func testFilters() {
        var rules = MeetingAlertRules()
        let events = [event("allday", allDay: true), event("declined", declined: true), event("solo", attendees: 0),
                      event("ignored", calendar: "Birthdays"), event("ok")]
        rules.ignoreCalendars = [" birthdays "]
        XCTAssertEqual(Set(MeetingAlertPlanner.plan(events, rules: rules, state: .init(), now: t0).map(\.event.id)), ["solo", "ok"])
        rules.requireAttendees = true
        XCTAssertEqual(MeetingAlertPlanner.plan(events, rules: rules, state: .init(), now: t0).map(\.event.id), ["ok"])
        rules.skipAllDay = false
        rules.skipDeclined = false
        rules.ignoreCalendars = []
        XCTAssertEqual(Set(MeetingAlertPlanner.plan(events, rules: rules, state: .init(), now: t0).map(\.event.id)), ["allday", "declined", "ignored", "ok"])
    }

    func testSnoozeComesBackAndReplacesOtherAlerts() {
        var rules = MeetingAlertRules()
        rules.alertAtStart = true
        let e = event(startIn: 1)
        var state = MeetingAlertState()
        let first = MeetingAlertPlanner.due([e], rules: rules, state: state, now: t0)
        XCTAssertEqual(first.map(\.kind), [.before])
        state.snooze(first[0], until: t0.addingTimeInterval(60))
        XCTAssertEqual(MeetingAlertPlanner.due([e], rules: rules, state: state, now: t0.addingTimeInterval(30)), [])
        let back = MeetingAlertPlanner.due([e], rules: rules, state: state, now: t0.addingTimeInterval(60))
        XCTAssertEqual(back.map(\.kind), [.snoozed])
        state.markShown(back[0])
        XCTAssertEqual(MeetingAlertPlanner.plan([e], rules: rules, state: state, now: t0.addingTimeInterval(61)), [], "the start alert is not shown again")
    }

    func testSnoozeStillShowsLateInTheMeeting() {
        let e = event(startIn: 0, length: 60)
        var state = MeetingAlertState()
        state.snooze(PlannedAlert(event: e, kind: .before, fireAt: t0), until: t0.addingTimeInterval(20 * 60))
        XCTAssertEqual(MeetingAlertPlanner.due([e], rules: .init(), state: state, now: t0.addingTimeInterval(20 * 60)).map(\.kind), [.snoozed])
    }

    func testMovedEventAlertsAgain() {
        var e = event(startIn: 1)
        var state = MeetingAlertState()
        state.markShown(MeetingAlertPlanner.due([e], rules: .init(), state: state, now: t0)[0])
        XCTAssertEqual(MeetingAlertPlanner.plan([e], rules: .init(), state: state, now: t0), [])
        e.start = e.start.addingTimeInterval(1800); e.end = e.end.addingTimeInterval(1800)
        XCTAssertEqual(MeetingAlertPlanner.plan([e], rules: .init(), state: state, now: t0).count, 1)
    }

    func testSkipDropsEveryAlertOfTheEvent() {
        var rules = MeetingAlertRules()
        rules.alertAtStart = true
        let e = event()
        var state = MeetingAlertState()
        state.skip(e)
        XCTAssertEqual(MeetingAlertPlanner.plan([e], rules: rules, state: state, now: t0), [])
    }

    func testNextAndOrder() {
        let a = event("a", startIn: 30), b = event("b", startIn: 5)
        XCTAssertEqual(MeetingAlertPlanner.next([a, b], rules: .init(), state: .init(), now: t0)?.event.id, "b")
        let c = event("c", startIn: 8)
        let both = MeetingAlertPlanner.due([c, b], rules: .init(), state: .init(), now: t0.addingTimeInterval(7 * 60))
        XCTAssertEqual(both.map(\.event.id), ["b", "c"], "the earlier meeting first")
    }

    func testPrune() {
        let e = event()
        var state = MeetingAlertState()
        state.skip(e)
        state.prune(now: e.end.addingTimeInterval(3600))
        XCTAssertFalse(state.shown.isEmpty)
        state.prune(now: e.end.addingTimeInterval(86400 + 1))
        XCTAssertTrue(state.shown.isEmpty)
    }

    func testCountdown() {
        XCTAssertEqual(MeetingAlertPlanner.countdown(to: t0.addingTimeInterval(58), now: t0), "in 0:58")
        XCTAssertEqual(MeetingAlertPlanner.countdown(to: t0.addingTimeInterval(245), now: t0), "in 4:05")
        XCTAssertEqual(MeetingAlertPlanner.countdown(to: t0.addingTimeInterval(7260), now: t0), "in 2h 1m")
        XCTAssertEqual(MeetingAlertPlanner.countdown(to: t0, now: t0), "now")
        XCTAssertEqual(MeetingAlertPlanner.countdown(to: t0, now: t0.addingTimeInterval(150)), "2m ago")
    }

    // MARK: Config

    func testConfigDefaultsAndWrongTypes() throws {
        let empty = try JSONDecoder().decode(Config.self, from: Data("{}".utf8)).alerts
        XCTAssertEqual(empty, Config.Alerts())
        XCTAssertTrue(empty.enabled)
        XCTAssertEqual(empty.leadMinutes, 1)
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"alerts": {"leadMinutes": "two", "alertAtStart": true, "ignoreCalendars": ["Birthdays"]}}"#.utf8)).alerts
        XCTAssertEqual(c.leadMinutes, 1)
        XCTAssertTrue(c.alertAtStart)
        XCTAssertEqual(c.rules.ignoreCalendars, ["Birthdays"])
        let negative = try JSONDecoder().decode(Config.self, from: Data(#"{"alerts": {"leadMinutes": -5}}"#.utf8)).alerts
        XCTAssertEqual(negative.leadMinutes, 0)
    }
}
