import AppKit
import ApplicationServices
import LauncherCore

/// Moves the focused window between zones through the Accessibility API.
final class ZoneManager {
    struct Zone {
        let frame: CGRect      // top-left origin, as the Accessibility API uses
        let display: String
        let position: String   // "left", "top right", ...
    }

    private let config: Config.Zones
    private var hotKeys: [HotKey] = []
    private lazy var drop = ZoneDropController(manager: self)
    /// Where we last put each window, so a window that cannot fill its zone exactly
    /// (terminals round to their cell grid, some apps have a minimum size) still moves on.
    private var placed: [(window: AXUIElement, zone: CGRect, frame: CGRect)] = []

    init(config: Config.Zones) {
        self.config = config
    }

    func start() {
        guard config.enabled else { return }
        for direction in ZoneDirection.allCases {
            guard let text = config.keys[direction.rawValue], !text.isEmpty else { continue }
            do {
                let spec = try HotKeySpec.parse(text)
                hotKeys.append(try HotKey(spec: spec) { [weak self] in self?.move(direction) })
            } catch {
                Log.write("zone hotkey \(direction.rawValue) (\(text)) failed: \(error)")
            }
        }
        // `Kea --zone right` (or left/up/down) presses a zone key from the shell.
        DistributedNotificationCenter.default().addObserver(forName: .init("directory.kea.launcher.zone"), object: nil, queue: .main) { [weak self] n in
            if let d = (n.object as? String).flatMap(ZoneDirection.init(rawValue:)) { self?.move(d) }
        }
        if config.dropZones { drop.start() }
        Log.write("zones: \(hotKeys.count) hotkeys, accessibility \(AXIsProcessTrusted() ? "granted" : "not granted")")
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that points at Privacy & Security › Accessibility.
    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: Zones

    func zones() -> [Zone] {
        guard let primary = NSScreen.screens.first else { return [] }
        let gap = CGFloat(config.gap)
        var out: [Zone] = []
        var displays: [(frame: CGRect, layout: ZoneLayout, name: String)] = []
        for screen in NSScreen.screens {
            let v = screen.visibleFrame
            let frame = CGRect(x: v.minX, y: primary.frame.maxY - v.maxY, width: v.width, height: v.height)
            displays.append((frame, layout(for: screen), screen.localizedName))
        }
        // Same order as ZoneNavigator.globalZones, keeping each display's name.
        displays.sort { $0.frame.minX != $1.frame.minX ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
        for d in displays {
            let rects = ZoneNavigator.globalZones(displays: [(d.frame, d.layout)], gap: gap)
            for r in rects {
                out.append(Zone(frame: r, display: d.name, position: Self.describe(r, in: d.frame, count: rects.count)))
            }
        }
        return out
    }

    private func layout(for screen: NSScreen) -> ZoneLayout {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let builtin = CGDisplayIsBuiltin(id) != 0
        let portrait = screen.frame.height > screen.frame.width
        for d in config.displays {
            let m = d.match.lowercased()
            let hit: Bool
            switch m {
            case "builtin", "laptop": hit = builtin
            case "portrait", "vertical": hit = portrait
            case "landscape", "horizontal": hit = !portrait
            case "main", "primary": hit = screen == NSScreen.screens.first
            case "*", "any": hit = true
            default: hit = screen.localizedName.lowercased().contains(m)
            }
            guard hit else { continue }
            do { return try ZoneLayout.parse(d.layout) } catch { Log.write("zone layout \"\(d.layout)\": \(error)") }
        }
        return .zone
    }

    private static func describe(_ r: CGRect, in display: CGRect, count: Int) -> String {
        guard count > 1 else { return "full" }
        let col = r.width > display.width * 0.9 ? "" : r.midX < display.midX - display.width * 0.1 ? "left" : r.midX > display.midX + display.width * 0.1 ? "right" : "middle"
        let row = r.height > display.height * 0.9 ? "" : r.midY < display.midY - display.height * 0.1 ? "top" : r.midY > display.midY + display.height * 0.1 ? "bottom" : "middle"
        let text = [row, col].filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? "full" : text
    }

    // MARK: Search results

    static let keywords: Set<String> = ["zones", "zone", "win"]

    func results(filter: String) -> [Result] {
        var out: [Result] = []
        if !Self.trusted {
            out.append(Result(id: "zones:access", title: "Allow Accessibility Access",
                              subtitle: "Kea needs it to move windows · Return opens Privacy & Security",
                              icon: NSImage(systemSymbolName: "lock.open", accessibilityDescription: nil),
                              action: .custom {
                                  Self.requestAccess()
                                  NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                              }))
        }
        let f = filter.lowercased().trimmingCharacters(in: .whitespaces)
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "the front window"
        for (i, z) in zones().enumerated() {
            let text = "\(z.display) \(z.position) \(i + 1)".lowercased()
            if !f.isEmpty, !f.split(separator: " ").allSatisfy({ text.contains($0) }) { continue }
            out.append(Result(id: "zones:\(i)", title: "Zone \(i + 1) · \(z.display) · \(z.position)",
                              subtitle: "\(Int(z.frame.width))×\(Int(z.frame.height)) · Return moves \(front) here",
                              icon: NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil),
                              action: .custom { [weak self] in self?.place(zone: i) }))
        }
        if f.isEmpty || "edit layouts settings".contains(f) {
            out.append(Result(id: "zones:edit", title: "Edit Zone Layouts", subtitle: "Kea Settings › Window Zones",
                              icon: NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil),
                              action: .custom { SettingsWindowController.shared.show() }))
        }
        if !config.enabled {
            out.insert(Result(id: "zones:off", title: "Zones are off", subtitle: "Turn them on with \"zones\": { \"enabled\": true } in config.json",
                              icon: NSImage(systemSymbolName: "rectangle.slash", accessibilityDescription: nil), action: .none), at: 0)
        }
        return out
    }

    // MARK: Moving

    /// Windows Kea minimized, newest last, so Up and Down restore the right one.
    private var minimized: [AXUIElement] = []
    /// Where the windows are now, for the `layout save` preview row: read off the main thread.
    private lazy var captured = Cached { [unowned self] in capture() }

    /// Each display's usable area (no menu bar or Dock), top-left origin.
    func displayAreas() -> [CGRect] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.map { s in
            let v = s.visibleFrame
            return CGRect(x: v.minX, y: primary.frame.maxY - v.maxY, width: v.width, height: v.height)
        }
    }

    /// The usable area of the display a frame mostly covers.
    func area(for frame: CGRect) -> CGRect? {
        func overlap(_ r: CGRect) -> CGFloat { let i = r.intersection(frame); return i.isNull ? 0 : i.width * i.height }
        return displayAreas().max { overlap($0) < overlap($1) }
    }

    /// The whole display, with the zone gap.
    private func maximizedFrame(in area: CGRect) -> CGRect {
        ZoneNavigator.globalZones(displays: [(area, .zone)], gap: CGFloat(config.gap)).first ?? area
    }

    /// Centred, smaller than the display: for reading and writing.
    private func focusFrame(in area: CGRect) -> CGRect {
        let w = (area.width * CGFloat(config.focusWidth)).rounded()
        let h = (area.height * CGFloat(config.focusHeight)).rounded()
        return CGRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w, height: h)
    }

    /// Up: a maximized window goes to focus view; any other window fills the display.
    private func grow(_ window: AXUIElement) {
        guard let frame = frame(of: window), let area = area(for: frame) else { return }
        let full = maximizedFrame(in: area)
        if close(frame, full, tolerance: 24) {
            place(window, in: focusFrame(in: area))
        } else {
            place(window, in: full)
        }
    }

    private func minimize(_ window: AXUIElement, app: AXUIElement) {
        // Pressing the yellow button behaves like Cmd+M; setting the attribute is the fallback.
        var button: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizeButtonAttribute as CFString, &button) == .success, let button,
           AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success {
        } else {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
        // With its last window gone, the app keeps focus (as with Cmd+M), so Down can bring it back.
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
                  self.windows(of: app).allSatisfy(self.isMinimized) else { return }
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        minimized.removeAll { CFEqual($0, window) }
        minimized.append(window)
        if minimized.count > 64 { minimized.removeFirst() }
    }

    /// Brings back the app's most recently minimized window. Returns false if it has none.
    @discardableResult
    private func restoreMinimized(of app: AXUIElement) -> Bool {
        let down = windows(of: app).filter(isMinimized)
        guard !down.isEmpty else { return false }
        // Ours first, newest first; windows minimized some other way after that.
        let window = minimized.reversed().first { m in down.contains { CFEqual($0, m) } } ?? down.last!
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        minimized.removeAll { CFEqual($0, window) }
        return true
    }

    private func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list.filter { w in
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &role)
            // Minimized windows report AXDialog, so keep those too.
            return (role as? String) == kAXStandardWindowSubrole as String || isMinimized(w)
        }
    }

    private func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success && (value as? Bool) == true
    }

    func move(_ direction: ZoneDirection) {
        guard let app = frontApp() else { return }
        let focused = focusedWindow(of: app)
        let window = focused.flatMap { isMinimized($0) ? nil : $0 }
        switch direction {
        case .up:
            // No window up: bring the last minimized one back instead.
            if let window { grow(window) } else { restoreMinimized(of: app) }
            return
        case .down:
            if let window {
                minimize(window, app: app)
            } else if windows(of: app).allSatisfy(isMinimized) {
                restoreMinimized(of: app)
            }
            return
        case .left, .right:
            break
        }
        guard let window, !isFullScreen(window) else { return }
        let all = zones().map(\.frame)
        guard let frame = frame(of: window) else { return }
        let target: Int?
        if let known = placed.first(where: { CFEqual($0.window, window) && close($0.frame, frame) }),
           let i = all.firstIndex(of: known.zone) {
            target = ZoneNavigator.target(from: i, direction, zones: all)
        } else if let loc = ZoneNavigator.locate(frame, in: all) {
            // A window that is not in a zone yet starts at its display's first zone.
            target = loc.snapped ? ZoneNavigator.target(from: loc.index, direction, zones: all)
                : ZoneNavigator.entry(for: frame, direction, displays: displayAreas(), zones: all)
        } else {
            target = nil
        }
        guard let target else { return }
        place(window, in: all[target])
    }

    /// Moves the focused window into zone `index` of `zones()`.
    func place(zone index: Int) {
        let all = zones()
        guard all.indices.contains(index), let app = frontApp(), let window = focusedWindow(of: app),
              !isMinimized(window), !isFullScreen(window) else { return }
        place(window, in: all[index].frame)
    }

    func place(_ window: AXUIElement, in zone: CGRect) {
        var app: pid_t = 0
        AXUIElementGetPid(window, &app)
        let axApp = AXUIElementCreateApplication(app)
        // Chrome and others animate every change while this is on, which also breaks the size.
        let enhanced = "AXEnhancedUserInterface" as CFString
        var was: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, enhanced, &was)
        let hadEnhanced = (was as? Bool) == true
        if hadEnhanced { AXUIElementSetAttributeValue(axApp, enhanced, kCFBooleanFalse) }

        // Size first so the window fits the target display, then move, then size again.
        set(window, size: zone.size)
        set(window, origin: zone.origin)
        set(window, size: zone.size)

        if hadEnhanced { AXUIElementSetAttributeValue(axApp, enhanced, kCFBooleanTrue) }
        let actual = frame(of: window) ?? zone
        placed.removeAll { CFEqual($0.window, window) }
        placed.append((window, zone, actual))
        if placed.count > 64 { placed.removeFirst() }
    }

    private func frontApp() -> AXUIElement? {
        guard Self.trusted else {
            Self.requestAccess()
            return nil
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        return app
    }

    private func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func isFullScreen(_ window: AXUIElement) -> Bool {
        var full: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &full) == .success && (full as? Bool) == true
    }

    func frame(of window: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private func set(_ window: AXUIElement, origin: CGPoint) {
        var p = origin
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v) }
    }

    private func set(_ window: AXUIElement, size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v) }
    }

    private func close(_ a: CGRect, _ b: CGRect, tolerance t: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) < t && abs(a.minY - b.minY) < t && abs(a.width - b.width) < t && abs(a.height - b.height) < t
    }
}

extension ZoneManager {
    func command(moveKey: String?) -> KeaCommand {
        KeaCommand(id: "zones", name: "Window Zones", keywords: Self.keywords,
                   help: [.init(keyword: "zones", summary: "Window zones per display; move the front window with \(moveKey ?? "the zone keys")", example: "zones · zones right")],
                   results: { [unowned self] in results(filter: $0.argument) })
    }
}

// MARK: Saved layouts

/// `layout save work` records where the front window of each app sits; `layout work`
/// puts them back. Frames are shares of a display, so a layout fits another display size.
extension ZoneManager {
    // KEA_LAYOUTS_FILE points checks at a scratch file.
    static let layoutsFile = ProcessInfo.processInfo.environment["KEA_LAYOUTS_FILE"].map { URL(fileURLWithPath: Paths.expand($0)) }
        ?? Paths.root.appendingPathComponent("layouts.json")

    /// nil: the file exists but is not valid (a hand edit with an error). Kea then does
    /// not write it, because a save would replace every layout in it.
    private func loadLayouts() -> [String: [WindowLayouts.Placement]]? {
        guard let data = try? Data(contentsOf: Self.layoutsFile) else {
            return FileManager.default.fileExists(atPath: Self.layoutsFile.path) ? nil : [:]
        }
        return try? JSONDecoder().decode([String: [WindowLayouts.Placement]].self, from: data)
    }

    private func saveLayouts(_ layouts: [String: [WindowLayouts.Placement]]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(layouts) { try? data.write(to: Self.layoutsFile, options: .atomic) }
    }

    /// The first normal window of an app that is not minimized.
    func mainWindow(of app: NSRunningApplication) -> AXUIElement? {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.5)
        if let w = focusedWindow(of: ax), !isMinimized(w), frame(of: w) != nil { return w }
        return windows(of: ax).first { !isMinimized($0) }
    }

    private func capture() -> [WindowLayouts.Placement] {
        // The screens and the app list come from the main thread. The Accessibility calls
        // (348 ms for all apps when cold) can run on the thread of the caller.
        let inputs = { (self.displayAreas(), NSScreen.screens.map(\.localizedName),
                        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isHidden }) }
        let (areas, names, apps) = Thread.isMainThread ? inputs() : DispatchQueue.main.sync(execute: inputs)
        return apps.compactMap { app in
            guard let id = app.bundleIdentifier, let w = mainWindow(of: app), !isFullScreen(w), let f = frame(of: w),
                  let i = WindowLayouts.displayIndex(for: f, areas: areas) else { return nil }
            return WindowLayouts.Placement(bundleID: id, app: app.localizedName ?? id, display: names[i], frame: WindowLayouts.fractions(of: f, in: areas[i]))
        }.sorted { $0.app < $1.app }
    }

    private func apply(_ placements: [WindowLayouts.Placement]) {
        let areas = displayAreas()
        let names = NSScreen.screens.map(\.localizedName)
        var moved = 0
        for p in placements {
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == p.bundleID }),
                  let w = mainWindow(of: app), !isFullScreen(w) else { continue }
            // The display with the saved name; if it is not connected, the first display.
            guard let area = names.firstIndex(of: p.display).map({ areas[$0] }) ?? areas.first else { continue }
            place(w, in: WindowLayouts.rect(p.frame, in: area))
            moved += 1
        }
        Log.write("layout: placed \(moved) of \(placements.count) windows")
    }

    func layoutResults(argument: String, refresh: @escaping () -> Void = {}) -> [Result] {
        let icon = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
        guard Self.trusted else {
            return [Result(id: "layout:access", title: "Layouts need the Accessibility permission", subtitle: "Return opens the request", icon: icon, action: .custom { Self.requestAccess() })]
        }
        guard let layouts = loadLayouts() else {
            return [Result(id: "layout:error", title: "layouts.json has an error", subtitle: "Kea does not change the file. Return opens it; correct the JSON",
                           icon: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil), action: .openPath(Self.layoutsFile.path))]
        }
        let arg = argument.trimmingCharacters(in: .whitespaces)
        let words = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = words.first?.lowercased() ?? ""
        let rest = words.count > 1 ? words[1].trimmingCharacters(in: .whitespaces) : ""
        if verb == "save" {
            guard !rest.isEmpty else {
                return [Result(id: "layout:save", title: "layout save <name>", subtitle: "Records where the front window of each app is now", icon: icon, action: .none)]
            }
            guard let now = captured.get(refresh: refresh) else {
                return [Result(id: "layout:save", title: "\(layouts[rest] == nil ? "Save" : "Replace") layout \"\(rest)\"",
                               subtitle: "Reading the windows…", icon: icon, action: .none)]
            }
            let summary = now.map(\.app).joined(separator: ", ")
            return [Result(id: "layout:save", title: "\(layouts[rest] == nil ? "Save" : "Replace") layout \"\(rest)\"",
                           subtitle: now.isEmpty ? "No windows found" : "\(now.count) windows: \(summary)", icon: icon,
                           action: now.isEmpty ? .none : .custom { [weak self] in
                               guard let self, var all = self.loadLayouts() else { return }
                               all[rest] = self.capture()
                               self.saveLayouts(all)
                               Notify.post(title: "Layout \"\(rest)\" saved", body: summary)
                           })]
        }
        if verb == "rm" || verb == "remove" {
            guard layouts[rest] != nil else {
                return [Result(id: "layout:rm", title: "No layout \"\(rest)\"", subtitle: "layout lists them all", icon: icon, action: .none)]
            }
            return [Result(id: "layout:rm", title: "Remove layout \"\(rest)\"", subtitle: "The windows do not move", icon: icon,
                           action: .custom { [weak self] in
                               guard let self, var all = self.loadLayouts() else { return }
                               all[rest] = nil
                               self.saveLayouts(all)
                           })]
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var rows = layouts.keys.sorted().filter { arg.isEmpty || $0.lowercased().contains(arg.lowercased()) }.map { name -> Result in
            let ps = layouts[name] ?? []
            let open = ps.filter { running.contains($0.bundleID) }
            let closed = ps.count - open.count
            return Result(id: "layout:\(name)", title: "Layout \"\(name)\"",
                          subtitle: open.map(\.app).joined(separator: ", ") + (closed > 0 ? " · \(closed) not open" : "") + " · layout rm \(name) removes",
                          icon: icon, action: .custom { [weak self] in
                              DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self?.apply(ps) }
                          })
        }
        if arg.isEmpty || rows.isEmpty {
            rows.append(Result(id: "layout:hint", title: "layout save <name>", subtitle: layouts.isEmpty ? "No layouts saved yet" : "Records where the windows are now",
                               icon: icon, action: .fill("layout save ")))
        }
        return rows
    }

    var layoutCommand: KeaCommand {
        KeaCommand(id: "layout", name: "Saved Window Layouts", keywords: ["layout", "layouts"],
                   help: [.init(keyword: "layout", summary: "Save where the windows are, and put them back", example: "layout save work · layout work · layout rm work")],
                   results: { [unowned self] in layoutResults(argument: $0.argument, refresh: $0.refresh) })
    }
}
