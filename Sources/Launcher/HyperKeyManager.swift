import AppKit
import IOKit
import LauncherCore

/// Caps Lock as a Hyper key (Control+Option+Command+Shift) in every app.
///
/// Two parts. `hidutil` remaps Caps Lock to F18 in the HID driver, so Caps Lock no longer
/// toggles capitals and sends a plain key that no app uses. A key event tap then holds the
/// Hyper state while F18 is down, adds the four modifier flags to every other key, and
/// drops F18 itself. Kea's own hotkeys with all four modifiers (`hyper+k`) then work with
/// Caps+K, like hotkeys of any other app.
///
/// The remap lasts only while Kea runs: quit, `hyper off`, and a SIGTERM put the old
/// mapping back. Kea remaps only after the tap works, so without Accessibility Caps Lock
/// stays Caps Lock.
final class HyperKeyManager {
    static let keywords: Set<String> = ["hyper", "capslock"]
    private static let hidutil = "/usr/bin/hidutil"

    private let settings: Config.HyperKey
    private var state: HyperState
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tapPlace = ""
    /// The Caps Lock mapping that someone else set before Kea's, put back when Hyper turns off.
    private var original: HyperMapping.Entry?
    /// Hidutil calls run in order, off the main thread, except the last one at quit.
    private let queue = DispatchQueue(label: "directory.kea.launcher.hyper")
    /// The last mapping that Kea read or wrote. Nil until the first read.
    private var lastMapping: [HyperMapping.Entry]?
    private var mappingProblem: String?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var reapplyWork: DispatchWorkItem?
    /// The HID state reported F18 down at the last press, so a lost key up can be found.
    private var hardwareSeesF18 = false
    private var lastRead = Date.distantPast

    var isOn: Bool { tap != nil }
    var mappingActive: Bool { lastMapping.map(HyperMapping.isActive) ?? false }

    init(settings: Config.HyperKey) {
        self.settings = settings
        state = HyperState(tapEscape: settings.tapEscape)
    }

    /// At launch: only when `hyperKey.enabled` is true.
    func startIfConfigured() {
        if settings.enabled { start() } else { Log.write("hyper key off (hyperKey.enabled is false)") }
    }

    func start() {
        guard tap == nil else { return }
        guard ZoneManager.trusted else {
            Log.write("hyper key not started: no Accessibility access")
            ZoneManager.requestAccess()
            return
        }
        guard installTap() else { return }
        if let target = Self.systemSettingsCapsTarget() {
            Log.write("hyper key: System Settings maps Caps Lock to \(HyperMapping.keyName(target)); macOS applies that first, so Caps+key sends \(HyperMapping.keyName(target)) only. Set Caps Lock to Caps Lock in Modifier Keys.")
        }
        watch()
        queue.async { [weak self] in self?.applyMapping(reason: "start") }
    }

    /// `hyper off` and quit. `sync` waits for hidutil, so the old mapping is back before Kea exits.
    func stop(sync: Bool = false) {
        guard tap != nil else { return }
        removeTap()
        unwatch()
        state.reset()
        let last = lastMapping
        if sync { queue.sync { removeMapping(last: last) } } else { queue.async { [weak self] in self?.removeMapping(last: last) } }
    }

    // MARK: Event tap

    private func installTap() -> Bool {
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        // The HID tap comes before every other tap and before hotkeys are matched, so
        // every app and Kea's own Carbon hotkeys see the modifiers. The session tap is
        // the fallback.
        for (place, location) in [("hid", CGEventTapLocation.cghidEventTap), ("session", .cgSessionEventTap)] {
            if let t = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: hyperCallback, userInfo: me) {
                tap = t
                tapPlace = place
                source = CFMachPortCreateRunLoopSource(nil, t, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: t, enable: true)
                Log.write("hyper key tap on (\(place))")
                return true
            }
        }
        Log.write("hyper key: could not create event tap")
        return false
    }

    private func removeTap() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(t)
        tap = nil
        source = nil
        Log.write("hyper key tap off")
    }

    /// macOS turns a tap off when it is slow or for secure input. The key up of F18 can be
    /// lost then, so Hyper is let go too: a stuck Hyper would make every key a shortcut.
    fileprivate func reenable() {
        state.reset()
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Returns nil to drop the event.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        switch type {
        case .keyDown, .keyUp:
            // Kea's own typing (snippets, tap-for-Esc) and other synthetic keys with a mark pass as they are.
            if event.getIntegerValueField(.eventSourceUserData) != 0 { return event }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let now = ProcessInfo.processInfo.systemUptime
            if code == HyperMapping.f18KeyCode {
                if type == .keyDown {
                    let wasHeld = state.isHeld
                    state.hyperDown(at: now)
                    if !wasHeld { hardwareSeesF18 = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code)) }
                } else if state.hyperUp(at: now) == .escape {
                    DispatchQueue.main.async { Self.postEscape() }
                }
                return nil
            }
            guard state.isHeld else { return event }
            // The key up of Caps Lock was lost (the HID state says it is up): let go.
            if hardwareSeesF18 && !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(HyperMapping.f18KeyCode)) {
                state.reset()
                return event
            }
            if type == .keyDown { _ = state.otherInput() }
            switch HyperMapping.modifiers(forKeyCode: code, arrowSpaces: settings.arrowSpaces) {
            case .hyper:
                event.flags.formUnion(Self.hyperFlags)
            case .controlOnly:
                // Keep the arrow's own flags (Fn, keypad); the other modifiers would make it a different shortcut.
                event.flags = event.flags.subtracting([.maskAlternate, .maskCommand, .maskShift, .maskAlphaShift]).union(.maskControl)
            }
            return event
        default:
            // A click while Hyper is held: the release is not a tap.
            _ = state.otherInput()
            return event
        }
    }

    private static let hyperFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
    private static let marker: Int64 = 0x48595052   // "HYPR"

    private static func postEscape() {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(HyperMapping.escapeKeyCode), keyDown: down)
            e?.flags = []
            e?.setIntegerValueField(.eventSourceUserData, value: marker)
            e?.post(tap: .cgSessionEventTap)
        }
    }

    /// Caps Lock's target in System Settings > Modifier Keys, from the global preferences of
    /// this host. It overrides Kea's mapping; Kea does not change System Settings itself.
    static func systemSettingsCapsTarget() -> UInt64? {
        let app = kCFPreferencesAnyApplication, user = kCFPreferencesCurrentUser, host = kCFPreferencesCurrentHost
        guard let keys = CFPreferencesCopyKeyList(app, user, host) as? [String] else { return nil }
        let wanted = keys.filter { $0.hasPrefix("com.apple.keyboard.modifiermapping.") }
        guard !wanted.isEmpty, let values = CFPreferencesCopyMultiple(wanted as CFArray, app, user, host) as? [String: Any] else { return nil }
        return HyperMapping.systemSettingsCapsTarget(in: values)
    }

    // MARK: hidutil (on `queue`)

    private func readMapping() -> [HyperMapping.Entry]? {
        let r = Proc.run(Self.hidutil, ["property", "--get", "UserKeyMapping"])
        guard r.status == 0, let entries = HyperMapping.parse(r.output) else {
            Log.write("hyper key: could not read hidutil UserKeyMapping (status \(r.status)): \(r.output.prefix(200))")
            return nil
        }
        return entries
    }

    private func write(_ entries: [HyperMapping.Entry]) -> Bool {
        let r = Proc.run(Self.hidutil, ["property", "--set", HyperMapping.json(entries)])
        guard r.status == 0 else {
            Log.write("hyper key: hidutil --set failed (status \(r.status)): \(r.output.prefix(200))")
            return false
        }
        return true
    }

    /// Adds Caps Lock to F18 to the current list. It writes again even when the entry is
    /// there, because a keyboard that was just connected may not have it yet.
    private func applyMapping(reason: String) {
        guard let current = readMapping() else {
            // A list Kea cannot read is not replaced: that could remove someone else's mappings.
            publish(nil, problem: "could not read the current key mapping (see the log)")
            return
        }
        if let foreign = HyperMapping.foreignCapsEntry(in: current) { original = foreign }
        let next = HyperMapping.applied(to: current)
        if write(next) {
            publish(next, problem: nil)
            Log.write("hyper key mapping on (\(reason)): Caps Lock → F18" + (original != nil ? ", replaced a Caps Lock mapping until off" : ""))
        } else {
            publish(current, problem: "hidutil could not set the mapping (see the log)")
        }
    }

    private func removeMapping(last: [HyperMapping.Entry]?) {
        let current = readMapping() ?? last ?? [HyperMapping.ours]
        let next = HyperMapping.removed(from: current, restoring: original)
        if write(next) {
            publish(next, problem: nil)
            Log.write("hyper key mapping off: Caps Lock restored")
        }
        original = nil
    }

    private func publish(_ mapping: [HyperMapping.Entry]?, problem: String?) {
        DispatchQueue.main.async { [weak self] in
            if let mapping { self?.lastMapping = mapping }
            self?.mappingProblem = problem
        }
    }

    // MARK: Wake and new keyboards

    private func watch() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append((ws, ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.scheduleReapply("wake") }))
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append((ws, ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.state.reset() }))
        }
        watchKeyboards()
    }

    private func unwatch() {
        for (center, o) in observers { center.removeObserver(o) }
        observers = []
        reapplyWork?.cancel()
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if let port = notifyPort {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    /// An IOKit notice for each new HID keyboard (USB or Bluetooth). It does not open the
    /// device, so it needs no Input Monitoring permission.
    private func watchKeyboards() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let match = IOServiceMatching("IOHIDDevice") as NSMutableDictionary
        match[kIOPropertyMatchKey] = ["PrimaryUsagePage": 1, "PrimaryUsage": 6]
        let me = Unmanaged.passUnretained(self).toOpaque()
        let status = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, match, { refcon, iterator in
            var any = false
            while case let s = IOIteratorNext(iterator), s != 0 { IOObjectRelease(s); any = true }
            if any, let refcon { Unmanaged<HyperKeyManager>.fromOpaque(refcon).takeUnretainedValue().scheduleReapply("keyboard connected") }
        }, me, &addedIterator)
        guard status == KERN_SUCCESS else { Log.write("hyper key: no keyboard notices (\(status))"); return }
        // The keyboards that are already there; this also arms the notice.
        while case let s = IOIteratorNext(addedIterator), s != 0 { IOObjectRelease(s) }
    }

    /// Waits a moment: after a wake or a connect, the HID system resets the mapping late.
    fileprivate func scheduleReapply(_ reason: String) {
        guard isOn else { return }
        state.reset()
        reapplyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isOn else { return }
            self.reenable()
            self.queue.async { self.applyMapping(reason: reason) }
        }
        reapplyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: Rows

    /// The rows read the mapping from hidutil at most every 2 s, off the main thread.
    private func refreshMapping(_ refresh: @escaping () -> Void) {
        guard Date().timeIntervalSince(lastRead) > 2 else { return }
        lastRead = Date()
        queue.async { [weak self] in
            guard let self, let m = self.readMapping() else { return }
            DispatchQueue.main.async {
                let changed = self.lastMapping != m
                self.lastMapping = m
                if changed { refresh() }
            }
        }
    }

    func results(argument: String, refresh: @escaping () -> Void) -> [Result] {
        refreshMapping(refresh)
        let arg = argument.trimmingCharacters(in: .whitespaces).lowercased()
        let icon = IconLoader.shared.icon(forSpec: "sf:capslock")
        var out: [Result] = []
        let trusted = ZoneManager.trusted
        if !trusted {
            out.append(Result(id: "hyper:access", title: "Allow Accessibility Access",
                              subtitle: "The Hyper key needs it to add the modifiers · Return opens Privacy & Security",
                              icon: IconLoader.shared.icon(forSpec: "sf:lock.open"),
                              action: .custom {
                                  ZoneManager.requestAccess()
                                  NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                              }))
        }
        let status: String
        if isOn {
            status = "Hyper key is on" + (mappingActive ? "" : " · Caps Lock is not remapped yet")
        } else {
            status = "Hyper key is off" + (mappingActive ? " · Caps Lock is still remapped to F18" : "")
        }
        let settingsTarget = Self.systemSettingsCapsTarget()
        if let settingsTarget {
            let name = HyperMapping.keyName(settingsTarget)
            out.append(Result(id: "hyper:settings", title: "System Settings Maps Caps Lock to \(name)",
                              subtitle: "macOS applies it before Kea, so Caps+key sends \(name) only · Return opens Keyboard: Keyboard Shortcuts > Modifier Keys > Caps Lock: Caps Lock",
                              icon: IconLoader.shared.icon(forSpec: "sf:exclamationmark.triangle"),
                              action: .custom { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!) }))
        }
        var detail = ["Caps Lock → F18: \(mappingActive ? "active" : "not active")",
                      "Accessibility: \(trusted ? "yes" : "no")"]
        if isOn { detail.append("tap: \(tapPlace)") }
        detail.append("tap for Esc: \(settings.tapEscape ? "on" : "off")")
        detail.append("Caps+←/→ changes Space: \(settings.arrowSpaces ? "on" : "off")")
        if let settingsTarget { detail.append("System Settings: Caps Lock → \(HyperMapping.keyName(settingsTarget))") }
        if let mappingProblem { detail.append(mappingProblem) }
        out.append(Result(id: "hyper:status", title: status, subtitle: detail.joined(separator: " · "), icon: icon, action: .none))

        let wantsOff = arg == "off" || arg == "stop"
        let wantsOn = arg == "on" || arg == "start"
        if isOn && !wantsOn {
            out.append(Result(id: "hyper:off", title: "Turn Off Hyper Key", subtitle: "Caps Lock is Caps Lock again until Kea restarts",
                              icon: icon, action: .custom { [weak self] in self?.stop() }))
        } else if !isOn && !wantsOff {
            // After Return is released, so its key up is not caught half way.
            out.append(Result(id: "hyper:on", title: "Turn On Hyper Key",
                              subtitle: "For this session · Caps Lock becomes Control+Option+Command+Shift in every app",
                              icon: icon, action: .custom { [weak self] in
                                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.start() }
                              }))
        }
        if !settings.enabled {
            let snippet = #""hyperKey": { "enabled": true, "tapEscape": false }"#
            out.append(Result(id: "hyper:config", title: "Turn On at Every Start",
                              subtitle: "Return copies \(snippet) · add it to ~/.launcher/config.json, then restart Kea",
                              icon: IconLoader.shared.icon(forSpec: "sf:doc.on.clipboard"), action: .item(.copy(snippet))))
        }
        out.append(Result(id: "hyper:bind", title: "Bind hyper+<key> as a Hotkey",
                          subtitle: "In Kea config, \"hyper+k\" means control+option+command+shift+k · other apps see the same four modifiers",
                          icon: IconLoader.shared.icon(forSpec: "sf:keyboard"), action: .none))
        return out
    }
}

private func hyperCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<HyperKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        me.reenable()
        return Unmanaged.passUnretained(event)
    }
    guard let out = me.handle(type, event) else { return nil }
    return Unmanaged.passUnretained(out)
}

extension HyperKeyManager {
    var command: KeaCommand {
        KeaCommand(id: "hyper", name: "Hyper Key", keywords: Self.keywords,
                   help: [.init(keyword: "hyper", summary: "Caps Lock as Control+Option+Command+Shift in every app", example: "hyper · hyper on · hyper off")],
                   results: { [unowned self] ctx in results(argument: ctx.argument, refresh: ctx.refresh) })
    }
}
