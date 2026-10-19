import AppKit
import ApplicationServices
import LauncherCore

/// Reads another app's window through the Accessibility API.
enum AX {
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    /// The first element below `root` (or `root` itself) for which `match` is true.
    static func first(in root: AXUIElement, maxDepth: Int = 40, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        if match(root) { return root }
        guard maxDepth > 0 else { return nil }
        for child in children(root) {
            if let hit = first(in: child, maxDepth: maxDepth - 1, where: match) { return hit }
        }
        return nil
    }

    static func all(in root: AXUIElement, maxDepth: Int = 40, where match: (AXUIElement) -> Bool) -> [AXUIElement] {
        var out = match(root) ? [root] : []
        guard maxDepth > 0 else { return out }
        for child in children(root) { out += all(in: child, maxDepth: maxDepth - 1, where: match) }
        return out
    }

    /// Where an element is on the screen (the origin is the top left of the main screen).
    static func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let p = position, let s = size, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    /// The element of an app that is at a point of the screen.
    static func element(of app: AXUIElement, at point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        return AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success ? hit : nil
    }

    static func parent(_ element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success, let v = value,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    @discardableResult
    static func press(_ element: AXUIElement) -> Bool { AXUIElementPerformAction(element, kAXPressAction as CFString) == .success }

    /// Asks again every 0.2 s until `find` gives something or the time is over.
    static func wait<T>(_ seconds: TimeInterval, for find: () -> T?) -> T? {
        let end = Date().addingTimeInterval(seconds)
        while true {
            if let found = find() { return found }
            if Date() >= end { return nil }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// The whole tree of an app as text, one element on each line. For finding out what
    /// an app shows to Accessibility.
    static func dump(pid: pid_t, maxDepth: Int = 40) -> String {
        let app = AXUIElementCreateApplication(pid)
        // Some apps build their tree only when an assistive tool says it is there.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        var lines: [String] = []
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard depth <= maxDepth, lines.count < 6000 else { return }
            var parts = [string(element, kAXRoleAttribute) ?? "?"]
            for (label, attribute) in [("sub", kAXSubroleAttribute), ("title", kAXTitleAttribute), ("value", kAXValueAttribute),
                                       ("desc", kAXDescriptionAttribute), ("id", kAXIdentifierAttribute), ("help", kAXHelpAttribute),
                                       ("label", "AXLabel"), ("roledesc", kAXRoleDescriptionAttribute)] {
                if let v = string(element, attribute), !v.isEmpty { parts.append("\(label)=\(v.prefix(140).replacingOccurrences(of: "\n", with: "⏎"))") }
            }
            let acts = actions(element).filter { $0 != "AXScrollToVisible" }
            if !acts.isEmpty { parts.append("actions=\(acts.joined(separator: ","))") }
            lines.append(String(repeating: "  ", count: depth) + parts.joined(separator: " | "))
            for child in children(element) { walk(child, depth + 1) }
        }
        walk(app, 0)
        return lines.joined(separator: "\n")
    }
}
