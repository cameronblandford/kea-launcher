import AppKit
import EventKit
import LauncherCore

/// Meeting alerts, like InYourFace: a full-screen alert on every display shortly before
/// each calendar event, with a Join button for its video call. Keywords: alerts, inyourface.
///
/// The rules (which events, when, snoozes) are in core MeetingAlerts.swift. This class
/// reads EventKit, keeps one timer for the next alert, and looks again when the calendar
/// changes, the Mac wakes, or the clock changes. A timer does not fire during sleep, so
/// the wake check is what shows an alert that came due while the lid was closed.
final class MeetingAlerter {
    static let keywords: Set<String> = ["alerts", "inyourface", "iyf"]

    private let calendar: CalendarStore
    let settings: Config.Alerts
    private let overlay: MeetingAlertOverlay
    private var state = MeetingAlertState()
    private(set) var events: [MeetingEvent] = []
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private(set) var isRunning = false
    private var reloadPending = false
    /// A recheck at least this often, in case a notification was missed.
    private static let poll: TimeInterval = 10 * 60
    /// How far ahead events are read.
    private static let horizon: TimeInterval = 36 * 3600

    init(calendar: CalendarStore, settings: Config.Alerts, appearance: Config.Appearance) {
        self.calendar = calendar
        self.settings = settings
        overlay = MeetingAlertOverlay(theme: Theme.resolve(appearance), snoozeMinutes: settings.snoozeMinutes, sound: settings.sound)
        overlay.onSnooze = { [weak self] alert in self?.snooze(alert) }
    }

    func start() {
        guard !isRunning, Bundle.main.bundleIdentifier != nil else { return }
        isRunning = true
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        func watch(_ center: NotificationCenter, _ name: Notification.Name) {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reloadSoon() }))
        }
        // EventKit posts this for every store, often several times in a row; one reload is enough.
        watch(nc, .EKEventStoreChanged)
        watch(nc, .NSSystemClockDidChange)
        watch(nc, .NSSystemTimeZoneDidChange)
        watch(ws, NSWorkspace.didWakeNotification)
        watch(ws, NSWorkspace.screensDidWakeNotification)
        watch(ws, NSWorkspace.sessionDidBecomeActiveNotification)
        reload()
        Log.write("meeting alerts on: \(Int(settings.leadMinutes))m before\(settings.alertAtStart ? " and at start" : ""), \(events.count) events read")
    }

    /// `Kea --alerts test` shows the preview in the running app.
    func installHook() {
        DistributedNotificationCenter.default().addObserver(forName: .init("directory.kea.launcher.alerts"), object: nil, queue: .main) { [weak self] note in
            if (note.object as? String) == "test" { self?.preview() }
        }
    }

    private func reloadSoon() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.reloadPending = false
            self?.reload()
        }
    }

    func reload() {
        let now = Date()
        events = calendar.meetingEvents(from: now.addingTimeInterval(-MeetingAlertPlanner.lateLimit - 60), to: now.addingTimeInterval(Self.horizon))
        check()
    }

    private func check() {
        let now = Date()
        state.prune(now: now)
        for alert in MeetingAlertPlanner.due(events, rules: settings.rules, state: state, now: now) {
            state.markShown(alert)
            Log.write("meeting alert: \(alert.kind.rawValue) \(alert.event.start)")
            overlay.show(alert)
        }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let now = Date()
        let next = MeetingAlertPlanner.next(events, rules: settings.rules, state: state, now: now)?.fireAt
        let fire = min(next ?? .distantFuture, now.addingTimeInterval(Self.poll))
        // The poll reads the calendar again; the alert time only checks what is read.
        let readAgain = next == nil || fire < next!
        let t = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            if readAgain { self?.reload() } else { self?.check() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func snooze(_ alert: PlannedAlert) {
        state.snooze(alert, until: Date().addingTimeInterval(settings.snoozeMinutes * 60))
        schedule()
    }

    /// Shows the alert for a test event that starts in one minute. Join opens Zoom's test page.
    func preview() {
        let start = Date().addingTimeInterval(60)
        let event = MeetingEvent(id: "kea-preview", title: "Kea Test Meeting", start: start, end: start.addingTimeInterval(1800),
                                 calendar: "Preview", location: "Room 4B", url: "https://zoom.us/test")
        let alert = PlannedAlert(event: event, kind: .before, fireAt: Date())
        overlay.show(alert, preview: true)
    }

    /// Shows the alert of a real event now, from the `alerts` list.
    func preview(_ event: MeetingEvent) {
        overlay.show(PlannedAlert(event: event, kind: .before, fireAt: Date()), preview: true)
    }

    func skip(_ event: MeetingEvent) {
        state.skip(event)
        Log.write("meeting alert skipped: \(event.start)")
        schedule()
    }

    var upcoming: [PlannedAlert] {
        MeetingAlertPlanner.plan(events, rules: settings.rules, state: state, now: Date()).filter { $0.fireAt > Date() }
    }
}

// MARK: - Command

extension MeetingAlerter {
    var command: KeaCommand {
        KeaCommand(id: "alerts", name: "Meeting Alerts", keywords: Self.keywords,
                   help: [.init(keyword: "alerts", summary: "Full-screen alert before each meeting", example: "alerts · alerts test")],
                   results: { [unowned self] in results(argument: $0.argument) })
    }

    private static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: d)
    }

    func results(argument: String) -> [Result] {
        let icon = IconLoader.shared.icon(forSpec: "sf:bell.badge")
        let arg = argument.trimmingCharacters(in: .whitespaces).lowercased()
        let previewRow = Result(id: "alerts:preview", title: "Preview Meeting Alert",
                                subtitle: "A test meeting that starts in 1 minute · Esc dismisses · Join opens Zoom's test page",
                                icon: IconLoader.shared.icon(forSpec: "sf:rectangle.inset.filled"),
                                action: .custom { [weak self] in DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.preview() } })
        if ["test", "preview", "demo"].contains(where: { $0.hasPrefix(arg) }), !arg.isEmpty { return [previewRow] }

        var status: Result
        let when = settings.leadMinutes > 0 ? "\(DurationParser.describe(settings.leadMinutes * 60)) before" : "at the start"
        if !settings.enabled {
            status = Result(id: "alerts:off", title: "Meeting Alerts Are Off",
                            subtitle: "Turn them on in Kea Settings › Meeting Alerts, or set alerts.enabled in config.json",
                            icon: icon, action: .none)
        } else if !calendar.authorized && Bundle.main.bundleIdentifier != nil {
            status = Result(id: "alerts:access", title: "Calendar Access Not Granted",
                            subtitle: "System Settings › Privacy & Security › Calendars › Kea: Full Access",
                            icon: icon, action: .item(.open("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars")))
        } else if let next = upcoming.first {
            status = Result(id: "alerts:next", title: "Next Alert at \(Self.clock(next.fireAt))",
                            subtitle: "\(next.event.title) · starts \(Self.clock(next.event.start)) · alerts \(when)\(settings.alertAtStart ? " and at the start" : "")",
                            icon: icon, action: .none)
        } else {
            status = Result(id: "alerts:none", title: "No Meetings Coming Up",
                            subtitle: "Nothing to alert in the next 36 hours · alerts \(when)", icon: icon, action: .none)
        }
        // One row per event: the first alert of each.
        var seen = Set<String>()
        let rows = upcoming.filter { seen.insert($0.event.key).inserted }.prefix(6).map { a -> Result in
            let link = a.event.joinLink.map { " · \($0.service.rawValue)" } ?? ""
            return Result(id: "alerts:event:\(a.event.key)", title: a.event.title,
                          subtitle: "Alert \(Self.clock(a.fireAt)) · \(CalendarStore.span(start: a.event.start, end: a.event.end, allDay: a.event.isAllDay))\(link) · Return previews, Cmd+Delete skips",
                          icon: IconLoader.shared.icon(forSpec: "sf:calendar"),
                          action: .custom { [weak self] in DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.preview(a.event) } },
                          onDelete: { [weak self] in self?.skip(a.event) })
        }
        return [status, previewRow] + (settings.enabled ? Array(rows) : [])
    }
}

// MARK: - Overlay

/// The alert windows: one per display, above full-screen apps, until Join, Snooze, or Dismiss.
/// Alerts that arrive while one shows wait in a queue; a newer alert of the same event
/// replaces the one on screen.
final class MeetingAlertOverlay {
    private let theme: Theme
    private let snoozeMinutes: Double
    private let sound: String
    private var windows: [NSWindow] = []
    private var views: [MeetingAlertView] = []
    private var current: PlannedAlert?
    private var currentIsPreview = false
    private var queue: [(PlannedAlert, Bool)] = []
    private var tick: Timer?
    var onSnooze: ((PlannedAlert) -> Void)?

    init(theme: Theme, snoozeMinutes: Double, sound: String) {
        self.theme = theme
        self.snoozeMinutes = snoozeMinutes
        self.sound = sound
    }

    func show(_ alert: PlannedAlert, preview: Bool = false) {
        if let current, current.event.key == alert.event.key {
            self.current = alert
            views.forEach { $0.alert = alert; $0.update(now: Date()) }
            return
        }
        if current != nil {
            queue.removeAll { $0.0.event.key == alert.event.key }
            queue.append((alert, preview))
            return
        }
        present(alert, preview: preview)
    }

    private func present(_ alert: PlannedAlert, preview: Bool) {
        current = alert
        currentIsPreview = preview
        let actions = MeetingAlertView.Actions(join: { [weak self] in self?.join() }, snooze: { [weak self] in self?.snooze() },
                                               dismiss: { [weak self] in self?.close() })
        for screen in NSScreen.screens {
            let w = AlertWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            // Above full-screen apps and the menu bar, on every Space.
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hidesOnDeactivate = false
            w.isReleasedWhenClosed = false
            w.isMovable = false
            let view = MeetingAlertView(frame: NSRect(origin: .zero, size: screen.frame.size), alert: alert, theme: theme,
                                        snoozeMinutes: snoozeMinutes, dark: nil, actions: actions)
            w.contentView = view
            w.setFrame(screen.frame, display: true)
            w.alphaValue = 0
            w.orderFrontRegardless()
            windows.append(w)
            views.append(view)
        }
        // The window on the screen with the pointer takes the keys (Return, S, Esc). It is a
        // non-activating panel, so the app in front keeps its place behind the alert.
        let mouse = NSEvent.mouseLocation
        let key = windows.first { $0.frame.contains(mouse) } ?? windows.first
        key?.makeKey()
        if let key, let v = key.contentView { key.makeFirstResponder(v) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            windows.forEach { $0.animator().alphaValue = 1 }
        }
        if !sound.isEmpty { NSSound(named: NSSound.Name(sound))?.play() }
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(tick!, forMode: .common)
        step()
    }

    private func step() {
        guard let current else { return }
        let now = Date()
        // Nobody needs the alert after the meeting is over.
        if now >= current.event.end { close(); return }
        views.forEach { $0.update(now: now) }
    }

    private func join() {
        guard let link = current?.event.joinLink else { close(); return }
        let target = link.appURL.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) != nil ? $0 : nil } ?? link.url
        Log.write("meeting alert: join \(link.service.rawValue)")
        NSWorkspace.shared.open(target)
        close()
    }

    private func snooze() {
        guard let current else { return }
        if !currentIsPreview { onSnooze?(current) }
        close()
    }

    func close() {
        tick?.invalidate(); tick = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        views = []
        current = nil
        let now = Date()
        queue.removeAll { now >= $0.0.event.end }
        if !queue.isEmpty {
            let (next, preview) = queue.removeFirst()
            present(next, preview: preview)
        }
    }

    /// `Kea --alerts-snapshot out.png [theme]`: the alert of a sample event, with no window:
    /// `out.png` (light), `out-dark.png` (dark), and `out-nolink.png` (light, no video link).
    /// It does not read config: a theme name picks the theme (System when left out).
    static func snapshot(to url: URL, themeName: String?) {
        var appearance = Config.Appearance()
        appearance.theme = themeName ?? "System"
        let theme = Theme.resolve(appearance)
        let now = Date()
        let start = Calendar.current.date(bySetting: .second, value: 0, of: now.addingTimeInterval(120)) ?? now
        var event = MeetingEvent(id: "sample", title: "Weekly Design Review", start: start, end: start.addingTimeInterval(1800),
                                 calendar: "Work", location: "Room 4B",
                                 notes: "Join Zoom Meeting https://us02web.zoom.us/j/8123456789?pwd=abc", otherAttendees: 5)
        let base = url.deletingPathExtension().path
        let at = start.addingTimeInterval(-58)
        let alert = PlannedAlert(event: event, kind: .before, fireAt: at)
        render(alert, theme: theme, dark: false, now: at, to: url)
        render(alert, theme: theme, dark: true, now: at, to: URL(fileURLWithPath: base + "-dark.png"))
        event.notes = ""
        event.title = "1:1 with Sam"
        render(PlannedAlert(event: event, kind: .atStart, fireAt: start), theme: theme, dark: false, now: start.addingTimeInterval(20),
               to: URL(fileURLWithPath: base + "-nolink.png"))
    }

    private static func render(_ alert: PlannedAlert, theme: Theme, dark: Bool, now: Date, to url: URL) {
        let size = NSSize(width: 1440, height: 900)
        let view = MeetingAlertView(frame: NSRect(origin: .zero, size: size), alert: alert, theme: theme, snoozeMinutes: 1, dark: dark,
                                    actions: .init(join: {}, snooze: {}, dismiss: {}))
        view.update(now: now)
        // Subview layers only exist inside a window; this one is never shown.
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        CATransaction.flush()
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        ctx.cgContext.scaleBy(x: scale, y: scale)
        view.layer?.render(in: ctx.cgContext)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

private final class AlertWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The content of one alert window: the title, the time, a countdown, the place, and the buttons.
final class MeetingAlertView: NSView {
    struct Actions {
        var join: () -> Void
        var snooze: () -> Void
        var dismiss: () -> Void
    }

    var alert: PlannedAlert { didSet { fill() } }
    private let theme: Theme
    private let actions: Actions
    private let isDark: Bool
    private let header = NSTextField(labelWithString: "")
    private let title = NSTextField(wrappingLabelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let countdown = NSTextField(labelWithString: "")
    private let place = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private var joinButton: AlertButton!
    private var stack: NSStackView!

    /// `dark` nil follows the theme, then the system.
    init(frame: NSRect, alert: PlannedAlert, theme: Theme, snoozeMinutes: Double, dark: Bool?, actions: Actions) {
        self.alert = alert
        self.theme = theme
        self.actions = actions
        isDark = dark ?? (theme.appearance.map { $0 == .darkAqua }
            ?? (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua))
        super.init(frame: frame)
        appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        wantsLayer = true
        build(snoozeMinutes: snoozeMinutes)
        fill()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var accent: NSColor { theme.accent ?? NSColor(hex: isDark ? "5e9eff" : "0a64d8")! }
    private var foreground: NSColor { isDark ? .white : NSColor(white: 0.08, alpha: 1) }
    private var secondary: NSColor { foreground.withAlphaComponent(0.62) }

    private func build(snoozeMinutes: Double) {
        let base = theme.background.map { isDark == ($0.brightness < 0.5) ? $0 : nil } ?? nil
        layer?.backgroundColor = (base ?? NSColor(hex: isDark ? "101217" : "f4f4f7")!).withAlphaComponent(0.97).cgColor
        if let skin = theme.skin {
            let opal = OpalView(frame: bounds, style: skin)
            opal.autoresizingMask = [.width, .height]
            opal.appearance = appearance
            addSubview(opal)
        }
        // A band of the accent color at the top, so the alert reads as an alert from across the room.
        let band = NSView(frame: NSRect(x: 0, y: bounds.height - 10, width: bounds.width, height: 10))
        band.wantsLayer = true
        band.layer?.backgroundColor = accent.cgColor
        band.autoresizingMask = [.width, .minYMargin]
        addSubview(band)

        let width = min(bounds.width - 120, 1100)
        header.font = .systemFont(ofSize: 17, weight: .bold)
        header.textColor = accent
        title.font = .systemFont(ofSize: bounds.height < 700 ? 48 : 68, weight: .bold)
        title.textColor = foreground
        title.alignment = .center
        title.maximumNumberOfLines = 3
        title.preferredMaxLayoutWidth = width
        time.font = .systemFont(ofSize: 26, weight: .medium)
        time.textColor = secondary
        countdown.font = .monospacedDigitSystemFont(ofSize: bounds.height < 700 ? 72 : 110, weight: .semibold)
        countdown.textColor = foreground
        place.font = .systemFont(ofSize: 20, weight: .regular)
        place.textColor = secondary
        place.alignment = .center
        place.maximumNumberOfLines = 2
        place.preferredMaxLayoutWidth = width
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = foreground.withAlphaComponent(0.4)

        let snoozeText = snoozeMinutes == 1 ? "Snooze 1 min" : "Snooze \(DurationParser.describe(snoozeMinutes * 60))"
        joinButton = AlertButton(title: "Join", fill: accent, text: .white, size: 26, action: { [weak self] in self?.actions.join() })
        let neutral = foreground.withAlphaComponent(isDark ? 0.14 : 0.09)
        let snooze = AlertButton(title: snoozeText, fill: neutral, text: foreground, size: 22, action: { [weak self] in self?.actions.snooze() })
        let dismiss = AlertButton(title: "Dismiss", fill: neutral, text: foreground, size: 22, action: { [weak self] in self?.actions.dismiss() })
        let buttons = NSStackView(views: [joinButton, snooze, dismiss])
        buttons.orientation = .horizontal
        buttons.spacing = 16

        stack = NSStackView(views: [header, title, time, countdown, place, buttons, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(26, after: title)
        stack.setCustomSpacing(4, after: time)
        stack.setCustomSpacing(30, after: place)
        stack.setCustomSpacing(22, after: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 10),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: width),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: width),
        ])
    }

    private func fill() {
        let e = alert.event
        let f = DateFormatter(); f.timeStyle = .short
        let calendarText = e.calendar.isEmpty ? "" : " · \(e.calendar.uppercased())"
        header.attributedStringValue = NSAttributedString(string: (alert.kind == .snoozed ? "SNOOZED MEETING" : "MEETING") + calendarText,
                                                          attributes: [.kern: 2.4, .font: header.font!, .foregroundColor: accent])
        title.stringValue = e.title
        time.stringValue = "\(f.string(from: e.start)) – \(f.string(from: e.end))"
        let link = e.joinLink
        // A location that is only the call link says nothing the Join button does not.
        var where_ = e.location.trimmingCharacters(in: .whitespacesAndNewlines)
        if let link, where_.contains(link.url.absoluteString) {
            where_ = where_.replacingOccurrences(of: link.url.absoluteString, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " ·,;-\n"))
        }
        place.stringValue = where_
        place.isHidden = where_.isEmpty
        joinButton.title = link.map { "Join \($0.service.rawValue)" } ?? "Join"
        joinButton.isHidden = link == nil
        hint.stringValue = link != nil ? "Return joins  ·  S snoozes  ·  Esc dismisses" : "Return or Esc dismisses  ·  S snoozes"
    }

    func update(now: Date) {
        countdown.stringValue = MeetingAlertPlanner.countdown(to: alert.event.start, now: now)
        countdown.textColor = now >= alert.event.start ? accent : foreground
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: actions.dismiss()                                           // Escape
        case 36, 76: alert.event.joinLink != nil ? actions.join() : actions.dismiss()   // Return, Enter
        case 1: actions.snooze()                                             // S
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { actions.dismiss() }
}

/// A large rounded button that draws in a layer, so the snapshot shows it as on screen.
private final class AlertButton: NSView {
    var title: String { didSet { label.stringValue = title; invalidateIntrinsicContentSize() } }
    private let label: NSTextField
    private let fill: NSColor
    private let action: () -> Void

    init(title: String, fill: NSColor, text: NSColor, size: CGFloat, action: @escaping () -> Void) {
        self.title = title
        self.fill = fill
        self.action = action
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = fill.cgColor
        label.font = .systemFont(ofSize: size, weight: .semibold)
        label.textColor = text
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalTo: label.widthAnchor, constant: size * 2.2),
            heightAnchor.constraint(equalToConstant: 64),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { layer?.backgroundColor = fill.blended(withFraction: 0.2, of: .black)?.cgColor }
    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = fill.cgColor
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

private extension NSColor {
    var brightness: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0.5 }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }
}
