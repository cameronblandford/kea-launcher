import Foundation

public struct HotKeySpec: Equatable {
    public enum Modifier: String, CaseIterable {
        case command, option, control, shift
    }

    public enum Key: Equatable {
        case letter(Character)
        case digit(Character)
        case space, `return`, escape, tab
        case left, right, up, down
        case function(Int)
    }

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
        public init(description: String) { self.description = description }
    }

    public var modifiers: Set<Modifier>
    public var key: Key

    public init(modifiers: Set<Modifier>, key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    /// Parses strings like `option+space`, `command+shift+k`, or `hyper+k`.
    public static func parse(_ text: String) throws -> HotKeySpec {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else {
            throw ParseError(description: "hotkey needs at least one modifier and a key: \(text)")
        }
        var mods = Set<Modifier>()
        for m in parts.dropLast() {
            // `hyper` is all four, the chord that Caps Lock sends when `hyperKey` is on.
            if m == "hyper" { mods.formUnion(Modifier.allCases); continue }
            guard let mod = Modifier(rawValue: m) else {
                throw ParseError(description: "unknown modifier: \(m)")
            }
            mods.insert(mod)
        }
        let keyText = parts.last!
        let key: Key
        switch keyText {
        case "space": key = .space
        case "return", "enter": key = .return
        case "escape", "esc": key = .escape
        case "tab": key = .tab
        case "left": key = .left
        case "right": key = .right
        case "up": key = .up
        case "down": key = .down
        default:
            if keyText.count == 1, let ch = keyText.first {
                if ch.isLetter { key = .letter(ch) }
                else if ch.isNumber { key = .digit(ch) }
                else { throw ParseError(description: "unknown key: \(keyText)") }
            } else if keyText.hasPrefix("f"), let n = Int(keyText.dropFirst()), (1...12).contains(n) {
                key = .function(n)
            } else {
                throw ParseError(description: "unknown key: \(keyText)")
            }
        }
        return HotKeySpec(modifiers: mods, key: key)
    }
}
