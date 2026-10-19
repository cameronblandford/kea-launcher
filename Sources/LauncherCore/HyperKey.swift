import Foundation

extension Config {
    /// `hyper`: Caps Lock acts as Control+Option+Command+Shift held together, in every app.
    /// Off by default, because it remaps the keyboard for the whole Mac while Kea runs.
    public struct HyperKey: Codable, Equatable {
        public var enabled = false
        /// A tap of Caps Lock alone (no other key, shorter than `HyperState.tapLimit`) sends Esc.
        public var tapEscape = false
        /// Caps+Left and Caps+Right send Control+Left and Control+Right: the macOS shortcuts
        /// that move one Space to the left or right.
        public var arrowSpaces = true
        public init() {}
        enum CodingKeys: String, CodingKey { case enabled, tapEscape, arrowSpaces }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
            tapEscape = (try? c.decodeIfPresent(Bool.self, forKey: .tapEscape)) ?? false
            arrowSpaces = (try? c.decodeIfPresent(Bool.self, forKey: .arrowSpaces)) ?? true
        }
    }
}

/// The `hidutil` key mapping that turns Caps Lock into F18. Kea reads the current
/// `UserKeyMapping`, adds or removes only its own entry, and writes the list back, so
/// mappings that the user or another tool set stay as they are.
public enum HyperMapping {
    /// HID usage page 7 (keyboard), usage 0x39: Caps Lock.
    public static let capsLock: UInt64 = 0x7_0000_0039
    /// HID usage page 7, usage 0x6D: F18. No Mac keyboard has it, so no app uses it.
    public static let f18: UInt64 = 0x7_0000_006D
    /// The virtual key code of F18 in key events (`kVK_F18`).
    public static let f18KeyCode: Int64 = 79
    public static let escapeKeyCode: Int64 = 53
    public static let leftArrowKeyCode: Int64 = 123
    public static let rightArrowKeyCode: Int64 = 124

    /// What the tap does to a key while Hyper is held.
    public enum Modifiers: Equatable {
        /// Control+Option+Command+Shift.
        case hyper
        /// Control only, so that Caps+Left and Caps+Right match the macOS "Move left a space"
        /// and "Move right a space" shortcuts (Control+Left and Control+Right by default).
        case controlOnly
    }

    public static func modifiers(forKeyCode code: Int64, arrowSpaces: Bool) -> Modifiers {
        arrowSpaces && (code == leftArrowKeyCode || code == rightArrowKeyCode) ? .controlOnly : .hyper
    }

    public struct Entry: Equatable {
        public var src: UInt64
        public var dst: UInt64
        public init(src: UInt64, dst: UInt64) { self.src = src; self.dst = dst }
    }

    public static let ours = Entry(src: capsLock, dst: f18)

    /// Reads the output of `hidutil property --get UserKeyMapping`: `(null)` when no
    /// mapping is set, or an old-style property list of dictionaries with decimal numbers.
    /// Nil when the text cannot be read; the caller must then not write a new list, or it
    /// could remove mappings that it did not understand.
    ///
    /// Newer `hidutil` versions print a table with one row for each HID service instead
    /// (`RegistryID  Key  Value`); a value can go on over the next lines. Each value is read
    /// as above. When all services have the same list, that list is the result; when they
    /// differ, nil, because Kea would write one list over all of them.
    public static func parse(_ output: String) -> [Entry]? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "(null)" { return [] }
        if text.hasPrefix("RegistryID") { return parseTable(text) }
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(text.utf8), options: [], format: nil),
              let items = plist as? [Any] else { return nil }
        var out: [Entry] = []
        for item in items {
            guard let d = item as? [String: Any],
                  let src = number(d["HIDKeyboardModifierMappingSrc"]),
                  let dst = number(d["HIDKeyboardModifierMappingDst"]) else { return nil }
            out.append(Entry(src: src, dst: dst))
        }
        return out
    }

    private static func parseTable(_ text: String) -> [Entry]? {
        var values: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if parts.count == 3, parts[0].allSatisfy(\.isHexDigit), parts[1] == "UserKeyMapping" {
                values.append(String(parts[2]))
            } else if !values.isEmpty {
                values[values.count - 1] += "\n" + line
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                return nil
            }
        }
        var lists: [[Entry]] = []
        // Some HID services never hold the property and always show "(null)", next to the
        // keyboards that hold the list (8 of 241 on one test Mac). They do not count.
        for value in values where value.trimmingCharacters(in: .whitespacesAndNewlines) != "(null)" {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("RegistryID"),
                  let list = parse(value) else { return nil }
            lists.append(list)
        }
        guard let first = lists.first else { return [] }
        return lists.allSatisfy { $0 == first } ? first : nil
    }

    private static func number(_ value: Any?) -> UInt64? {
        if let n = value as? NSNumber { return n.uint64Value }
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
        if s.lowercased().hasPrefix("0x") { return UInt64(s.dropFirst(2), radix: 16) }
        return UInt64(s)
    }

    public static func isActive(_ entries: [Entry]) -> Bool { entries.contains(ours) }

    /// The key that System Settings (Keyboard > Keyboard Shortcuts > Modifier Keys) maps
    /// Caps Lock to, read from the global preferences of the current host
    /// (`com.apple.keyboard.modifiermapping.<vendor>-<product>-0`). macOS applies this
    /// mapping before `UserKeyMapping`, so Caps Lock never reaches Kea's F18 entry while it
    /// is set. Nil when no keyboard maps Caps Lock to another key.
    public static func systemSettingsCapsTarget(in preferences: [String: Any]) -> UInt64? {
        for key in preferences.keys.sorted() where key.hasPrefix("com.apple.keyboard.modifiermapping.") {
            guard let items = preferences[key] as? [[String: Any]] else { continue }
            for d in items {
                if let src = number(d["HIDKeyboardModifierMappingSrc"]), src == capsLock,
                   let dst = number(d["HIDKeyboardModifierMappingDst"]), dst != capsLock {
                    return dst
                }
            }
        }
        return nil
    }

    /// The name that System Settings shows for a modifier key target.
    public static func keyName(_ usage: UInt64) -> String {
        switch usage {
        case 0x7_0000_00E0, 0x7_0000_00E4: return "Control"
        case 0x7_0000_00E1, 0x7_0000_00E5: return "Shift"
        case 0x7_0000_00E2, 0x7_0000_00E6: return "Option"
        case 0x7_0000_00E3, 0x7_0000_00E7: return "Command"
        case 0x7_0000_0029: return "Escape"
        case 0xFF_0000_0003: return "Globe"
        case 0, 0x7_0000_0000: return "No Action"
        default: return String(format: "0x%llX", usage)
        }
    }

    /// A Caps Lock mapping that someone else set (Caps Lock to Control, for example). Kea
    /// replaces it while Hyper is on and puts it back when Hyper turns off.
    public static func foreignCapsEntry(in entries: [Entry]) -> Entry? {
        entries.first { $0.src == capsLock && $0 != ours }
    }

    /// The list with Caps Lock to F18 in it. A key can have one mapping only, so any other
    /// Caps Lock entry goes; every other entry stays in its place.
    public static func applied(to entries: [Entry]) -> [Entry] {
        entries.filter { $0.src != capsLock } + [ours]
    }

    /// The list without Kea's entry, with the Caps Lock mapping from before (if any) back.
    public static func removed(from entries: [Entry], restoring original: Entry?) -> [Entry] {
        var out = entries.filter { $0 != ours }
        if let original, !out.contains(where: { $0.src == capsLock }) { out.append(original) }
        return out
    }

    /// The argument of `hidutil property --set`. Decimal numbers, so it is plain JSON.
    public static func json(_ entries: [Entry]) -> String {
        let items = entries.map { "{\"HIDKeyboardModifierMappingSrc\":\($0.src),\"HIDKeyboardModifierMappingDst\":\($0.dst)}" }
        return "{\"UserKeyMapping\":[" + items.joined(separator: ",") + "]}"
    }
}

/// Whether Hyper is held, and what each F18 event does. The app's event tap feeds it the
/// F18 key (Caps Lock after the remap) and the other keys; it adds the four modifier
/// flags to other keys while `isHeld` is true.
public struct HyperState: Equatable {
    /// A press of Caps Lock alone that is longer than this sends nothing, so a hold that
    /// changed its mind does not type Esc.
    public static let tapLimit: TimeInterval = 0.5

    public enum Effect: Equatable {
        case none
        /// Send one Esc press (tap-for-Esc).
        case escape
    }

    public private(set) var isHeld = false
    /// Another key or a click came while Hyper was held: the release is not a tap.
    public private(set) var used = false
    private var downAt: TimeInterval = 0
    public var tapEscape: Bool

    public init(tapEscape: Bool = false) { self.tapEscape = tapEscape }

    /// F18 down. Key repeat sends more downs while it is held; they change nothing.
    public mutating func hyperDown(at time: TimeInterval) {
        guard !isHeld else { return }
        isHeld = true
        used = false
        downAt = time
    }

    public mutating func hyperUp(at time: TimeInterval) -> Effect {
        guard isHeld else { return .none }
        isHeld = false
        let tap = !used && time - downAt <= Self.tapLimit
        return tapEscape && tap ? .escape : .none
    }

    /// Any other key down or click. Returns true when Hyper must be added to it.
    public mutating func otherInput() -> Bool {
        guard isHeld else { return false }
        used = true
        return true
    }

    /// Sleep, a lost key up, or Hyper turned off: let go without a tap.
    public mutating func reset() {
        isHeld = false
        used = false
    }
}
