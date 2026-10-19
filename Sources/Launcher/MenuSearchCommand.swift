import AppKit
import LauncherCore

/// `menu`: search the menu bar items of the front app; Return chooses one.
final class MenuSearchCommand {
    private struct Item {
        let path: [String]
        let shortcut: [String]
        let enabled: Bool
        let element: AXUIElement
    }
    private var cache: (pid: pid_t, at: Date, items: [Item])?
    /// The app whose menus are being read now, off the main thread.
    private var reading: pid_t?
    /// The newest query's refresh, as in `Cached`: a late answer updates the rows on screen now.
    private var latestRefresh: () -> Void = {}
    private var refreshing = false

    private static func attr<T>(_ e: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    private static func shortcut(_ e: AXUIElement) -> [String] {
        guard let char: String = attr(e, "AXMenuItemCmdChar") else { return [] }
        return KeyCaps.menu(char: char, modifiers: attr(e, "AXMenuItemCmdModifiers") ?? 0)
    }

    private static func collect(_ e: AXUIElement, path: [String], depth: Int, into items: inout [Item]) {
        guard depth < 6, items.count < 3000 else { return }
        let children: [AXUIElement] = Self.attr(e, kAXChildrenAttribute as String) ?? []
        for child in children {
            let role: String = Self.attr(child, kAXRoleAttribute as String) ?? ""
            if role == kAXMenuRole as String { collect(child, path: path, depth: depth + 1, into: &items); continue }
            let title: String = Self.attr(child, kAXTitleAttribute as String) ?? ""
            guard !title.isEmpty else { continue }
            let sub: [AXUIElement] = Self.attr(child, kAXChildrenAttribute as String) ?? []
            if sub.isEmpty {
                if role == kAXMenuItemRole as String {
                    items.append(Item(path: path + [title], shortcut: Self.shortcut(child), enabled: Self.attr(child, kAXEnabledAttribute as String) ?? true, element: child))
                }
            } else {
                collect(child, path: path + [title], depth: depth + 1, into: &items)
            }
        }
    }

    /// Walks the menu tree of an app. It takes about 100 ms, and up to 1 s for each call to an
    /// app that does not respond, so it runs off the main thread.
    private static func read(pid: pid_t) -> [Item] {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 1)
        guard let bar: AXUIElement = { () -> AXUIElement? in
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ax, kAXMenuBarAttribute as CFString, &v) == .success, let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
            return (v as! AXUIElement)
        }() else { return [] }
        var items: [Item] = []
        let tops: [AXUIElement] = attr(bar, kAXChildrenAttribute as String) ?? []
        // The first top item is the Apple menu: the same in every app, so it is left out.
        for top in tops.dropFirst() {
            let title: String = attr(top, kAXTitleAttribute as String) ?? ""
            collect(top, path: [title], depth: 0, into: &items)
        }
        return items
    }

    /// The last answer for this app, or nil before the first one. An answer older than 20 s
    /// is read again (an empty one after 3 s: the app possibly did not respond), and
    /// `refresh` runs when the new answer is in.
    private func items(for app: NSRunningApplication, refresh: @escaping () -> Void) -> [Item]? {
        let pid = app.processIdentifier
        // The coordinator answers a refresh with a call that has an empty refresh; keep ours.
        if !refreshing { latestRefresh = refresh }
        let known = cache.flatMap { $0.pid == pid ? $0 : nil }
        if let known, Date().timeIntervalSince(known.at) < (known.items.isEmpty ? 3 : 20) { return known.items }
        if reading != pid {
            reading = pid
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let found = Self.read(pid: pid)
                DispatchQueue.main.async { [self] in
                    // The front app changed during the read: the newer read gives the answer.
                    guard reading == pid else { return }
                    cache = (pid, Date(), found)
                    reading = nil
                    refreshing = true
                    latestRefresh()
                    refreshing = false
                }
            }
        }
        return known?.items
    }

    func results(argument: String, refresh: @escaping () -> Void = {}) -> [Result] {
        let icon = NSImage(systemSymbolName: "filemenu.and.selection", accessibilityDescription: nil)
        guard ZoneManager.trusted else {
            return [Result(id: "menu:access", title: "Menu search needs the Accessibility permission", subtitle: "Return opens the request",
                           icon: icon, action: .custom { ZoneManager.requestAccess() })]
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return [Result(id: "menu:none", title: "No app is in front", subtitle: "Open Kea from the app whose menus you want", icon: icon, action: .none)]
        }
        let name = app.localizedName ?? "the front app"
        guard let all = items(for: app, refresh: refresh) else {
            return [Result(id: "menu:loading", title: "Reading the menus of \(name)…", subtitle: "", icon: icon, action: .none)]
        }
        let term = argument.trimmingCharacters(in: .whitespaces)
        let ranked: [Item]
        if term.isEmpty {
            ranked = Array(all.filter(\.enabled).prefix(40))
        } else {
            ranked = all.compactMap { item -> (Item, Double)? in
                // The item's own name counts most; the whole path also matches ("view zoom").
                let own = FuzzyMatcher.score(query: term, candidate: item.path.last ?? "")
                let whole = FuzzyMatcher.score(query: term, candidate: item.path.joined(separator: " "))
                guard let best = [own.map { $0 + 20 }, whole].compactMap({ $0 }).max() else { return nil }
                return (item, best - (item.enabled ? 0 : 1000))
            }.sorted { $0.1 > $1.1 }.prefix(40).map(\.0)
        }
        if ranked.isEmpty {
            return [Result(id: "menu:empty", title: all.isEmpty ? "\(name) shows no menus" : "No menu item matches \"\(term)\"", subtitle: name, icon: icon, action: .none)]
        }
        return ranked.enumerated().map { i, item in
            let trail = item.path.dropLast().joined(separator: " › ")
            let sub = [trail, item.enabled ? "" : "not available now"].filter { !$0.isEmpty }.joined(separator: " · ")
            return Result(id: "menu:\(i):\(item.path.joined(separator: "/"))", title: item.path.last ?? "", subtitle: "\(name) · \(sub)",
                          icon: app.icon ?? icon, action: item.enabled ? .custom { [weak self] in
                              AXUIElementPerformAction(item.element, kAXPressAction as CFString)
                              self?.cache = nil   // checkmarks and names can change
                          } : .none, keys: item.shortcut)
        }
    }

    var command: KeaCommand {
        KeaCommand(id: "menu", name: "Menu Search", keywords: ["menu"],
                   help: [.init(keyword: "menu", summary: "Search the menus of the front app; Return chooses the item", example: "menu export · menu zoom")],
                   results: { [unowned self] in results(argument: $0.argument, refresh: $0.refresh) })
    }
}
