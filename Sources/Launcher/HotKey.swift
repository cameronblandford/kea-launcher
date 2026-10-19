import Carbon
import LauncherCore

/// Global hotkey via Carbon. No Accessibility permission needed.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let callback: () -> Void
    private static var registry: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    init(spec: HotKeySpec, callback: @escaping () -> Void) throws {
        self.callback = callback
        id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.registry[id] = self

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            HotKey.registry[hkID.id]?.callback()
            return noErr
        }, 1, &eventType, nil, &handler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C4E4348), id: id) // "LNCH"
        let status = RegisterEventHotKey(HotKey.keyCode(spec.key), HotKey.modifierFlags(spec.modifiers),
                                         hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            throw RegisterError(status: status)
        }
    }

    struct RegisterError: Error, CustomStringConvertible {
        let status: OSStatus
        /// Another app (or Kea itself) already has this key combination.
        var isTaken: Bool { status == OSStatus(eventHotKeyExistsErr) }
        var description: String { "RegisterEventHotKey failed with status \(status)" + (isTaken ? " (hotkey taken)" : "") }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        HotKey.registry[id] = nil
    }

    private static func modifierFlags(_ mods: Set<HotKeySpec.Modifier>) -> UInt32 {
        var f: UInt32 = 0
        if mods.contains(.command) { f |= UInt32(cmdKey) }
        if mods.contains(.option) { f |= UInt32(optionKey) }
        if mods.contains(.control) { f |= UInt32(controlKey) }
        if mods.contains(.shift) { f |= UInt32(shiftKey) }
        return f
    }

    private static let letters: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
    ]
    private static let digits: [Character: Int] = [
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]
    private static let functions: [Int: Int] = [
        1: kVK_F1, 2: kVK_F2, 3: kVK_F3, 4: kVK_F4, 5: kVK_F5, 6: kVK_F6,
        7: kVK_F7, 8: kVK_F8, 9: kVK_F9, 10: kVK_F10, 11: kVK_F11, 12: kVK_F12,
    ]

    private static func keyCode(_ key: HotKeySpec.Key) -> UInt32 {
        switch key {
        case .letter(let c): return UInt32(letters[c] ?? kVK_ANSI_A)
        case .digit(let c): return UInt32(digits[c] ?? kVK_ANSI_0)
        case .space: return UInt32(kVK_Space)
        case .return: return UInt32(kVK_Return)
        case .escape: return UInt32(kVK_Escape)
        case .tab: return UInt32(kVK_Tab)
        case .left: return UInt32(kVK_LeftArrow)
        case .right: return UInt32(kVK_RightArrow)
        case .up: return UInt32(kVK_UpArrow)
        case .down: return UInt32(kVK_DownArrow)
        case .function(let n): return UInt32(functions[n] ?? kVK_F1)
        }
    }
}
