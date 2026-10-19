import AppKit
import LauncherCore

/// `clean 1m` swallows every key press for a while so the keyboard can be wiped.
/// The mouse and trackpad keep working: an on-screen panel counts down and has an
/// Unlock button, and the lock always ends on time.
final class KeyboardLock {
    static let keywords: Set<String> = ["clean", "kblock", "keylock"]
    static let defaultSeconds: TimeInterval = 60

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var until: Date?
    private var tick: Timer?
    private var panel: NSPanel?
    private var label: NSTextField?
    fileprivate var swallowed = 0

    var isLocked: Bool { tap != nil }

    init() {
        // `Kea --kblock 5s` or `--kblock off` from the shell.
        DistributedNotificationCenter.default().addObserver(forName: .init("directory.kea.launcher.kblock"), object: nil, queue: .main) { [weak self] n in
            guard let self, let arg = n.object as? String else { return }
            if arg == "off" { self.unlock() } else if let d = DurationParser.parse(arg) { self.lock(seconds: d.seconds) }
        }
    }

    static let maxSeconds: TimeInterval = 15 * 60

    func lock(seconds requested: TimeInterval) {
        guard ZoneManager.trusted else { ZoneManager.requestAccess(); return }
        // Capped here, not only in the row, so no path can lock the keyboard for long.
        let seconds = min(requested, Self.maxSeconds)
        unlock()
        // Masks for key down/up, modifier changes, and media/brightness keys (NX_SYSDEFINED = 14).
        let types: [UInt64] = [CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue, 14].map { UInt64($0) }
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: keyboardLockCallback, userInfo: me) else {
            Log.write("keyboard lock: could not create event tap")
            return
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        swallowed = 0
        until = Date().addingTimeInterval(seconds)
        showPanel()
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.step() }
        step()
        Log.write("keyboard locked for \(DurationParser.describe(seconds))")
    }

    @objc func unlock() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(t)
        tap = nil
        source = nil
        tick?.invalidate()
        tick = nil
        until = nil
        panel?.orderOut(nil)
        Log.write("keyboard unlocked, \(swallowed) key events swallowed")
    }

    /// macOS turns a tap off if it is slow or during secure input; turn it back on.
    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func step() {
        guard let until else { return }
        let left = until.timeIntervalSinceNow
        if left <= 0 { unlock(); return }
        label?.stringValue = "Keyboard locked · \(DurationParser.format(left.rounded(.up)))"
    }

    private func showPanel() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 150),
                            styleMask: [.nonactivatingPanel, .hudWindow, .utilityWindow, .titled], backing: .buffered, defer: false)
            p.title = "Kea"
            p.level = .screenSaver
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            let icon = NSImageView(image: NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil) ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: 28, weight: .regular)
            let text = NSTextField(labelWithString: "")
            text.font = .monospacedDigitSystemFont(ofSize: 17, weight: .medium)
            let button = NSButton(title: "Unlock", target: self, action: #selector(unlock))
            button.bezelStyle = .rounded
            let stack = NSStackView(views: [icon, text, button])
            stack.orientation = .vertical
            stack.spacing = 10
            stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
            p.contentView = stack
            panel = p
            label = text
        }
        if let screen = NSScreen.main ?? NSScreen.screens.first, let p = panel {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.midY - p.frame.height / 2))
        }
        panel?.orderFrontRegardless()
    }

    // MARK: Results

    func results(argument: String) -> [Result] {
        let icon = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        if isLocked {
            return [Result(id: "kblock:off", title: "Unlock Keyboard", subtitle: nil, icon: icon, action: .custom { [weak self] in self?.unlock() })]
        }
        let arg = argument.trimmingCharacters(in: .whitespaces)
        guard let seconds = arg.isEmpty ? Self.defaultSeconds : DurationParser.parse(arg).flatMap({ $0.label.isEmpty ? $0.seconds : nil }) else {
            return [Result(id: "kblock:bad", title: "Could not read \"\(arg)\"", subtitle: "Try clean, clean 30s, clean 2m", icon: icon, action: .none)]
        }
        let capped = min(seconds, Self.maxSeconds)
        return [Result(id: "kblock:on", title: "Lock Keyboard for \(DurationParser.describe(capped))",
                       subtitle: "For cleaning · mouse and trackpad still work · click Unlock to end early" + (capped < seconds ? " · 15m at most" : ""),
                       icon: icon,
                       // Start after the Return key is released, so its key-up is not left hanging.
                       action: .custom { [weak self] in
                           DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.lock(seconds: capped) }
                       })]
    }
}

private func keyboardLockCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let lock = Unmanaged<KeyboardLock>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        lock.reenable()
        return Unmanaged.passUnretained(event)
    }
    lock.swallowed += 1
    return nil
}

extension KeyboardLock {
    var command: KeaCommand {
        KeaCommand(id: "clean", name: "Keyboard Lock", keywords: Self.keywords,
                   help: [.init(keyword: "clean", summary: "Lock the keyboard for cleaning; the mouse can unlock", example: "clean · clean 30s")],
                   results: { [unowned self] in results(argument: $0.argument) })
    }
}
