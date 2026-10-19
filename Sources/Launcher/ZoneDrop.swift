import AppKit
import ApplicationServices
import LauncherCore

/// Drop zones: hold Shift while you drag a window by its title bar, and every zone shows
/// as a gray rectangle. Let go over a zone and the window fills it; let go near the
/// border of two zones and it spans both. Release Shift before the mouse button and the
/// window stays where you put it.
///
/// Kea only watches the mouse (it does not take events away), so macOS still moves the
/// window. Kea finds out that a drag moves a window by looking at the window under the
/// pointer two times: a window that goes where the pointer goes is being dragged.
///
/// Where a window is comes from the window server (`CGWindowList`), not from the
/// Accessibility API. During a drag many apps answer Accessibility with the place the
/// window had before the drag, or with a place from a moment ago; the first version
/// compared that with the pointer and saw "the window does not move". Accessibility is
/// used only at the end, to set the frame.
final class ZoneDropController {
    private unowned let manager: ZoneManager
    private var monitors: [Any] = []

    private struct Tracked {
        var id: CGWindowID
        var pid: pid_t
    }

    private enum State {
        case idle
        /// The window under the pointer, where it was, where the pointer was, and how
        /// many more times to look when it is not clear yet.
        case armed(Tracked, CGRect, CGPoint, Int)
        case dragging(Tracked)
        /// This drag does not move a window; nothing more until the next mouse down.
        case other
    }
    private var state = State.idle
    private var overlay: ZoneDropOverlay?
    private var zones: [CGRect] = []
    private var displays: [CGRect] = []
    private var hovered: [Int] = []

    init(manager: ZoneManager) { self.manager = manager }

    /// Kea always listens for the modifier keys only, which change seldom. The mouse
    /// monitors exist only while Shift is down, so a drag without Shift (a text selection,
    /// a scroll bar, any window move) does not wake Kea at all.
    func start() {
        guard monitors.isEmpty else { return }
        let changed: (NSEvent) -> Void = { [weak self] e in self?.shiftChanged(e.modifierFlags.contains(.shift)) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: changed) { monitors.append(m) }
        // Shift that goes up while a Kea window has the keys is not a global event.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { changed($0); return $0 }) { monitors.append(m) }
    }

    private var mouseMonitors: [Any] = []

    private func shiftChanged(_ down: Bool) {
        guard down != !mouseMonitors.isEmpty else { return }
        reset()
        if down {
            func watch(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) {
                if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { mouseMonitors.append(m) }
            }
            watch(.leftMouseDown) { [weak self] _ in self?.reset() }
            watch(.leftMouseDragged) { [weak self] e in self?.moved(shift: e.modifierFlags.contains(.shift)) }
            watch(.leftMouseUp) { [weak self] e in self?.released(shift: e.modifierFlags.contains(.shift)) }
            // Shift pressed in the middle of a drag: start to look now, not at the next move.
            moved(shift: true)
        } else {
            mouseMonitors.forEach(NSEvent.removeMonitor)
            mouseMonitors = []
        }
    }

    /// The pointer in the coordinates of the window server and the Accessibility API (y
    /// goes down from the top of the main display).
    private static func pointer() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func reset() {
        state = .idle
        hide()
    }

    private func hide() {
        overlay?.close()
        overlay = nil
        hovered = []
    }

    private func moved(shift: Bool) {
        guard NSEvent.pressedMouseButtons & 1 == 1 else { return }
        switch state {
        case .idle:
            guard shift, ZoneManager.trusted else { return }
            let point = Self.pointer()
            if let found = Self.windowUnder(point) {
                state = .armed(found.window, found.bounds, point, 4)
            } else {
                Log.write("zones: drop: no window of another app under the pointer")
                state = .other
            }
        case .armed(let window, let bounds, let pointer, let tries):
            let now = Self.pointer()
            guard shift, hypot(now.x - pointer.x, now.y - pointer.y) >= 10 else { return }
            guard let after = Self.bounds(of: window.id) else { return state = .other }
            if ZoneDrop.isWindowDrag(windowBefore: bounds, windowAfter: after, pointerBefore: pointer, pointerAfter: now, tolerance: 12) {
                begin(window)
            } else if tries > 0 {
                // Not clear yet. macOS starts to move a window a few points into the drag,
                // and a window that macOS had tiled goes back to its old size when the drag
                // starts. A real resize changes the size at every look, so it runs out of tries.
                state = .armed(window, after, now, tries - 1)
            } else {
                func describe(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))" }
                Log.write("zones: drop: not a window drag: window \(describe(bounds)) to \(describe(after)), pointer \(Int(pointer.x)),\(Int(pointer.y)) to \(Int(now.x)),\(Int(now.y))")
                state = .other
            }
        case .dragging:
            show()
        case .other:
            break
        }
    }

    private func begin(_ window: Tracked) {
        state = .dragging(window)
        zones = manager.zones().map(\.frame)
        displays = manager.displayAreas()
        if NSEvent.modifierFlags.contains(.shift) { show() }
    }

    private func show() {
        guard !zones.isEmpty else { return }
        if overlay == nil { overlay = ZoneDropOverlay(zones: zones) }
        let now = ZoneDrop.targets(at: Self.pointer(), zones: zones, displays: displays)
        if now != hovered {
            hovered = now
            overlay?.highlight(ZoneDrop.frame(of: now, zones: zones))
        }
    }

    private func released(shift: Bool) {
        defer { reset() }
        guard case .dragging(let window) = state, shift, overlay != nil,
              let frame = ZoneDrop.frame(of: ZoneDrop.targets(at: Self.pointer(), zones: zones, displays: displays), zones: zones) else { return }
        place(window, in: frame, tries: 8)
    }

    /// Sets the window's frame a moment after the drop: macOS must let go of the window
    /// first, and the app must know the window's new place before Kea can find the
    /// window in the app's own list by that place.
    private func place(_ window: Tracked, in frame: CGRect, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self, manager] in
            guard let self else { return }
            if let element = Self.element(for: window) {
                guard !manager.isFullScreen(element) else { return }
                manager.place(element, in: frame)
                Log.write("zones: dropped a window into \(Int(frame.width))×\(Int(frame.height)) at \(Int(frame.minX)),\(Int(frame.minY))")
            } else if tries > 0 {
                self.place(window, in: frame, tries: tries - 1)
            } else {
                Log.write("zones: drop: the dropped window was not found in its app's window list (not a standard window?)")
            }
        }
    }

    // MARK: - The window server's view

    /// The front window at a point, when it is a normal window of another app.
    private static func windowUnder(_ point: CGPoint) -> (window: Tracked, bounds: CGRect)? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let own = getpid()
        for info in list {
            // Layer 0 is where normal windows are. Kea's panel stays on screen at zero
            // opacity (on another layer), so its place must not count.
            guard (info[kCGWindowLayer as String] as? Int) == 0, ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.contains(point) else { continue }
            return (Tracked(id: id, pid: pid), bounds)
        }
        return nil
    }

    private static func bounds(of id: CGWindowID) -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
        return (list.first?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
    }

    /// The Accessibility element of a window the window server knows: the standard window
    /// of the app that is at the same place.
    private static func element(for window: Tracked) -> AXUIElement? {
        guard let bounds = bounds(of: window.id) else { return nil }
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success, let windows = value as? [AXUIElement] else { return nil }
        return windows.first { w in
            guard AX.string(w, kAXSubroleAttribute) == (kAXStandardWindowSubrole as String), let f = AX.frame(w) else { return false }
            return abs(f.minX - bounds.minX) < 3 && abs(f.minY - bounds.minY) < 3 && abs(f.width - bounds.width) < 3 && abs(f.height - bounds.height) < 3
        }
    }

    /// `Kea --zonedrop-snapshot out.png`: the overlay for the main display as a picture,
    /// on a plain background, with one zone under the pointer.
    static func snapshot(manager: ZoneManager, to url: URL) {
        guard let screen = NSScreen.screens.first else { return }
        let zones = manager.zones().map(\.frame)
        let view = ZoneDropView(zones: zones, screen: screen)
        view.backdrop = NSColor(white: 0.93, alpha: 1)
        let local = zones.filter { screen.frame.intersects(ZoneDropOverlay.cocoa($0)) }
        view.highlighted = local.last
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("\(zones.count) zones, \(local.count) on \(screen.localizedName)")
    }
}

/// One clear window over each display with the zones drawn in it. The windows take no
/// clicks and no focus.
final class ZoneDropOverlay {
    private var windows: [NSWindow] = []
    private var views: [ZoneDropView] = []

    /// A rectangle of the Accessibility API (y down from the top of the main display) in
    /// Cocoa screen coordinates (y up from its bottom).
    static func cocoa(_ r: CGRect) -> NSRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    init(zones: [CGRect]) {
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .floating
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let view = ZoneDropView(zones: zones, screen: screen)
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
            views.append(view)
        }
    }

    /// The frame the window will get, or nil for none.
    func highlight(_ frame: CGRect?) {
        for view in views where view.highlighted != frame { view.highlighted = frame }
    }

    func close() {
        windows.forEach { $0.close() }
        windows = []
        views = []
    }
}

final class ZoneDropView: NSView {
    private let zones: [NSRect]
    /// Accessibility coordinates, as the zones are given.
    var highlighted: CGRect? { didSet { needsDisplay = true } }
    /// Only for the snapshot; the real overlay is clear.
    var backdrop: NSColor?
    private let origin: NSPoint

    init(zones: [CGRect], screen: NSScreen) {
        origin = screen.frame.origin
        self.zones = zones.map(ZoneDropOverlay.cocoa).filter { screen.frame.intersects($0) }.map { $0.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        if let backdrop {
            backdrop.setFill()
            bounds.fill()
        }
        for zone in zones {
            // Drawn a little smaller than the zone, so zones with no gap still read as separate boxes.
            let path = NSBezierPath(roundedRect: zone.insetBy(dx: 5, dy: 5), xRadius: 12, yRadius: 12)
            NSColor(white: 0.5, alpha: 0.22).setFill()
            path.fill()
            NSColor(white: 1, alpha: 0.5).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
        guard let highlighted else { return }
        let target = ZoneDropOverlay.cocoa(highlighted).offsetBy(dx: -origin.x, dy: -origin.y)
        guard target.intersects(bounds) else { return }
        let path = NSBezierPath(roundedRect: target.insetBy(dx: 5, dy: 5), xRadius: 12, yRadius: 12)
        NSColor.controlAccentColor.withAlphaComponent(0.32).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
        path.lineWidth = 2.5
        path.stroke()
    }
}
