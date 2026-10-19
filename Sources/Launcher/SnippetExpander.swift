import AppKit
import LauncherCore

/// Text expansion in every app: type a trigger (`;td`) and it becomes its text.
///
/// The triggers live in `~/.launcher/snippets.json` (`{"trigger": "text"}`). A key event
/// tap reads typed characters into a buffer no longer than the longest trigger; nothing
/// typed is stored or logged. The tap needs the Accessibility permission, like zones.
final class SnippetExpander {
    static let keywords: Set<String> = ["snip", "snippet", "snippets"]
    // KEA_SNIPPETS_FILE points checks at a scratch file.
    static let file = ProcessInfo.processInfo.environment["KEA_SNIPPETS_FILE"].map { URL(fileURLWithPath: Paths.expand($0)) }
        ?? Paths.root.appendingPathComponent("snippets.json")
    /// Marks the key events Kea posts, so the tap does not read its own typing.
    fileprivate static let marker: Int64 = 0x4B4541

    private(set) var snippets: [String: String] = [:]
    private var buffer = Snippets.Buffer(triggers: [])
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var mouseMonitor: Any?
    /// The file exists but is not valid JSON (a hand edit with an error). Kea then never
    /// writes it: a save would replace every snippet in it with the one new entry.
    private var unreadable = false

    init() { load() }

    private func load() {
        if let data = try? Data(contentsOf: Self.file), let d = try? JSONDecoder().decode([String: String].self, from: data) {
            snippets = d
        } else if !FileManager.default.fileExists(atPath: Self.file.path) {
            snippets = Snippets.defaults
        } else {
            unreadable = true
            Log.write("snippets: snippets.json is not valid JSON; expansion is off and Kea will not change the file")
        }
        buffer = Snippets.Buffer(triggers: Array(snippets.keys))
    }

    private func save() {
        guard !unreadable else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(snippets) { try? data.write(to: Self.file, options: .atomic) }
        buffer = Snippets.Buffer(triggers: Array(snippets.keys))
    }

    func start() {
        guard tap == nil else { return }
        guard ZoneManager.trusted else { Log.write("snippets: no Accessibility permission, expansion is off"); return }
        if !FileManager.default.fileExists(atPath: Self.file.path) { save() }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: snippetCallback, userInfo: me) else {
            Log.write("snippets: could not create event tap")
            return
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        // A click moves the caret, so a half-typed trigger no longer counts.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.buffer.reset() }
        Log.write("snippets: \(snippets.count) triggers active")
    }

    fileprivate func reenable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    /// Called for each key down. Always lets the key through.
    fileprivate func key(_ event: CGEvent) {
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return }
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { buffer.reset(); return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        switch code {
        case 51: buffer.backspace(); return                      // Delete
        case 36, 76, 48, 53, 123, 124, 125, 126, 115, 116, 117, 119, 121: buffer.reset(); return   // Return, Tab, Esc, arrows, Home/End/Page
        default: break
        }
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return }
        let typed = String(utf16CodeUnits: chars, count: length)
        guard let trigger = buffer.type(typed), let template = snippets[trigger] else { return }
        // After this key reaches the app: remove the trigger, then type the text.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.replace(trigger: trigger, template: template) }
    }

    private func replace(trigger: String, template: String) {
        let text = Snippets.expand(template, clipboard: NSPasteboard.general.string(forType: .string) ?? "")
        let src = CGEventSource(stateID: .combinedSessionState)
        func post(_ e: CGEvent?) {
            e?.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            e?.flags = []
            e?.post(tap: .cgSessionEventTap)
        }
        for _ in 0..<trigger.count {
            post(CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true))
            post(CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false))
        }
        // Typed as Unicode text, in pieces (an event holds 20 UTF-16 units), so the
        // clipboard is not touched.
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            var end = min(i + 20, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            let piece = Array(units[i..<end])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: piece.count, unicodeString: piece)
                post(e)
            }
            i = end
        }
    }

    // MARK: Command

    private static func icon(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }

    func results(argument: String) -> [Result] {
        let arg = argument.trimmingCharacters(in: .whitespaces)
        let lower = arg.lowercased()
        if unreadable {
            return [Result(id: "snip:error", title: "snippets.json has an error", subtitle: "Kea does not change the file. Return opens it; correct the JSON, then restart Kea",
                           icon: Self.icon("exclamationmark.triangle"), action: .openPath(Self.file.path))]
        }
        if lower == "new" || lower.hasPrefix("new ") {
            guard let new = Snippets.parseNew(String(arg.dropFirst(3))) else {
                return [Result(id: "snip:new", title: "snip new <trigger> <text>", subtitle: "Example: snip new ;sig Best, Sam · {date} {date+1} {time} {clipboard} are filled in",
                               icon: Self.icon("plus.circle"), action: .none)]
            }
            let replaces = snippets[new.trigger] != nil
            return [Result(id: "snip:add", title: "\(replaces ? "Change" : "Add") \(new.trigger) → \(new.expansion)",
                           subtitle: "Now it gives: \(Snippets.expand(new.expansion))", icon: Self.icon("plus.circle"),
                           action: .custom { [weak self] in
                               self?.snippets[new.trigger] = new.expansion
                               self?.save()
                               Notify.post(title: "Snippet saved", body: "\(new.trigger) → \(new.expansion)")
                           })]
        }
        if lower.hasPrefix("rm ") || lower.hasPrefix("remove ") {
            let trigger = arg.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
            guard let text = snippets[trigger] else {
                return [Result(id: "snip:rm", title: "No snippet \"\(trigger)\"", subtitle: "snip lists them all", icon: Self.icon("minus.circle"), action: .none)]
            }
            return [Result(id: "snip:rm", title: "Remove \(trigger)", subtitle: text, icon: Self.icon("minus.circle"),
                           action: .custom { [weak self] in self?.snippets[trigger] = nil; self?.save() })]
        }
        var rows = snippets.keys.sorted()
            .filter { lower.isEmpty || $0.lowercased().contains(lower) || (snippets[$0] ?? "").lowercased().contains(lower) }
            .map { t -> Result in
                let text = snippets[t] ?? ""
                let now = Snippets.expand(text)
                return Result(id: "snip:\(t)", title: "\(t) → \(text)", subtitle: (now == text ? "" : "now: \(now) · ") + "Return copies · snip rm \(t) removes",
                              icon: Self.icon("text.cursor"), action: .item(.copy(now)))
            }
        if lower.isEmpty {
            let state = tap != nil ? "Type a trigger in any app to expand it" : "Expansion is off: Kea needs the Accessibility permission"
            rows.append(Result(id: "snip:hint", title: "snip new <trigger> <text>", subtitle: state, icon: Self.icon("plus.circle"), action: .fill("snip new ")))
            rows.append(Result(id: "snip:file", title: "Open snippets.json", subtitle: "Edit by hand; restart Kea to load", icon: Self.icon("doc.text"),
                               action: .openPath(Self.file.path)))
        }
        return rows
    }

    var command: KeaCommand {
        KeaCommand(id: "snippets", name: "Snippets", keywords: Self.keywords,
                   help: [.init(keyword: "snip", summary: "Text expansion in every app: type a trigger, get its text", example: "snip · snip new ;sig Best, Sam · snip rm ;sig")],
                   results: { [unowned self] in results(argument: $0.argument) })
    }
}

private func snippetCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let me = Unmanaged<SnippetExpander>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { me.reenable() }
        else if type == .keyDown { me.key(event) }
    }
    return Unmanaged.passUnretained(event)
}
