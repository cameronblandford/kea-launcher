import Foundation

/// The keys of a shortcut, one string for each key cap that a row draws.
public enum KeyCaps {
    /// A menu item's shortcut from its Accessibility values. `modifiers` bits: 1 Shift,
    /// 2 Option, 4 Control, 8 "no Command". The order is the one macOS menus use.
    public static func menu(char: String, modifiers: Int) -> [String] {
        let c = char.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty || char == " " else { return [] }
        var caps: [String] = []
        if modifiers & 4 != 0 { caps.append("⌃") }
        if modifiers & 2 != 0 { caps.append("⌥") }
        if modifiers & 1 != 0 { caps.append("⇧") }
        if modifiers & 8 == 0 { caps.append("⌘") }
        caps.append(names[char] ?? c.uppercased())
        return caps
    }

    private static let names: [String: String] = [
        " ": "Space", "\r": "↩", "\u{3}": "⌤", "\t": "⇥", "\u{8}": "⌫", "\u{7F}": "⌫", "\u{1B}": "esc",
    ]
}
