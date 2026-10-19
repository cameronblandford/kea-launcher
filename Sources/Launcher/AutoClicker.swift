import AppKit
import LauncherCore

/// Left clicks at the pointer on a timer, until the hotkey, Esc, sleep, screen lock, or quit.
/// It replaces a Hammerspoon autoclicker (same hotkey, same 0.02 s). The pointer can
/// move while it runs: each tick clicks where the pointer is now.
final class AutoClicker {
    static let keywords: Set<String> = ["autoclicker", "click", "clicker"]

    private let settings: Config.AutoClick
    private var state = AutoClickState()
    private var hotKey: HotKey?
    private var timer: Timer?
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var clicks = 0
    private var since: Date?
    /// Why the hotkey is not active, for the rows. Nil when it works or is turned off.
    private(set) var hotKeyProblem: String?
    /// Called when it starts or stops, so the menu bar can show it.
    var onChange: ((Bool) -> Void)?

    var isOn: Bool { state.isOn }
    var interval: TimeInterval { settings.effectiveInterval }
    var rate: String { AutoClickPlan.rate(interval) }

    init(settings: Config.AutoClick) {
        self.settings = settings
    }

    /// Registers the toggle hotkey. A failure (often Hammerspoon, which uses the same
    /// key combination) is logged; the keyword still works.
    func start() {
        let text = settings.hotkey.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { Log.write("autoclick hotkey off (empty autoclick.hotkey)"); return }
        do {
            hotKey = try HotKey(spec: try HotKeySpec.parse(text)) { [weak self] in self?.handle(.toggle) }
            Log.write("autoclick hotkey registered: \(text)")
        } catch let e as HotKey.RegisterError where e.isTaken {
            hotKeyProblem = "hotkey taken by another app (Hammerspoon?)"
            Log.write("autoclick hotkey taken: \(text) is registered by another app (Hammerspoon?); \(e)")
        } catch {
            hotKeyProblem = "hotkey error: \(error)"
            Log.write("autoclick hotkey error: \(text): \(error)")
        }
    }

    func handle(_ event: AutoClickState.Event) {
        switch state.handle(event, trusted: ZoneManager.trusted) {
        case .none: break
        case .needAccess:
            Log.write("autoclick not started: no Accessibility access")
            ZoneManager.requestAccess()
            Notify.post(title: "Autoclicker needs Accessibility", body: "Allow Kea in Privacy & Security › Accessibility, then try again.")
        case .start: begin()
        case .stop(let reason): end(reason: reason)
        }
    }

    private func begin() {
        clicks = 0
        since = Date()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.click() }
        // Common modes, so it keeps clicking while a menu is open.
        RunLoop.main.add(t, forMode: .common)
        timer = t
        watchForStops()
        Log.write("autoclick on (\(rate), every \(interval) s)")
        onChange?(true)
    }

    private func end(reason: String) {
        timer?.invalidate()
        timer = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        for (center, o) in observers { center.removeObserver(o) }
        observers = []
        let seconds = since.map { Date().timeIntervalSince($0) } ?? 0
        since = nil
        Log.write("autoclick off (\(reason)), \(clicks) clicks in \(String(format: "%.1f", seconds)) s")
        onChange?(false)
    }

    private func click() {
        // A new event with no source reads the pointer position in global, top-left coordinates.
        guard let at = CGEvent(source: nil)?.location else { return }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left) else { continue }
            // No modifiers, like hs.eventtap.leftClick: the hotkey's Ctrl+Option+Cmd may still
            // be held for the first clicks, and must not turn them into Cmd-clicks.
            e.flags = []
            e.post(tap: .cgSessionEventTap)
        }
        clicks += 1
    }

    /// Esc in any app, system sleep, display sleep, a fast user switch, and screen lock.
    private func watchForStops() {
        let esc: (NSEvent) -> Bool = { $0.keyCode == 53 }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if esc(e) { self?.handle(.escape) }
        }) { monitors.append(m) }
        // The global monitor does not see keys sent to Kea's own windows (the panel).
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if esc(e), self?.isOn == true { self?.handle(.escape) }
            return e
        }) { monitors.append(m) }

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append((ws, ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.handle(.sleep) }))
        }
        let dist = DistributedNotificationCenter.default()
        observers.append((dist, dist.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.handle(.screenLock)
        }))
    }

    /// For the menu bar tooltip and the status row.
    var statusText: String {
        guard isOn, let since else { return "Off" }
        return "Clicking at \(rate) for \(DurationParser.format(Date().timeIntervalSince(since).rounded()))"
    }

    private var hotkeyText: String {
        let text = settings.hotkey.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return "No hotkey (autoclick.hotkey is empty)" }
        let label = "Hotkey \(AutoClickPlan.hotkeyLabel(text))"
        return hotKeyProblem.map { "\(label): \($0)" } ?? label
    }

    // MARK: - Rows

    func results(argument: String) -> [Result] {
        let icon = IconLoader.shared.icon(forSpec: "sf:cursorarrow.click.2")
        let arg = argument.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [Result] = []
        if !ZoneManager.trusted && !isOn {
            out.append(Result(id: "autoclick:access", title: "Allow Accessibility Access",
                              subtitle: "The autoclicker needs it to click · Return opens Privacy & Security",
                              icon: IconLoader.shared.icon(forSpec: "sf:lock.open"),
                              action: .custom {
                                  ZoneManager.requestAccess()
                                  NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                              }))
        }
        let every = "Every \(String(format: "%g", interval)) s (autoclick.interval)"
        if isOn {
            out.append(Result(id: "autoclick:stop", title: "Stop Autoclicker", subtitle: "\(statusText) · Esc also stops",
                              icon: icon, action: .custom { [weak self] in self?.handle(.stop) }))
        } else if arg != "off" && arg != "stop" {
            // The action waits for Return to be released, then clicks where the pointer is.
            out.append(Result(id: "autoclick:start", title: "Start Autoclicker",
                              subtitle: "Left clicks at the pointer, \(rate) · Esc or the hotkey stops",
                              icon: icon, action: .custom { [weak self] in
                                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.handle(.start) }
                              }))
        } else {
            out.append(Result(id: "autoclick:status", title: "Autoclicker is off", subtitle: "Nothing to stop", icon: icon, action: .none))
        }
        let keyIcon = IconLoader.shared.icon(forSpec: "sf:keyboard")
        out.append(Result(id: "autoclick:hotkey", title: hotkeyText, subtitle: "Toggles the autoclicker in any app · set autoclick.hotkey in config",
                          icon: keyIcon, action: .none))
        out.append(Result(id: "autoclick:interval", title: every, subtitle: "\(rate) · at least \(String(format: "%g", AutoClickPlan.minInterval)) s",
                          icon: IconLoader.shared.icon(forSpec: "sf:timer"), action: .none))
        return out
    }
}

extension AutoClicker {
    var command: KeaCommand {
        KeaCommand(id: "autoclicker", name: "Autoclicker", keywords: Self.keywords,
                   help: [.init(keyword: "autoclicker", summary: "Click at the pointer until stopped", example: "click")],
                   live: (interval: 1, isLive: { [weak self] in self?.isOn == true }),
                   results: { [unowned self] in results(argument: $0.argument) })
    }
}
