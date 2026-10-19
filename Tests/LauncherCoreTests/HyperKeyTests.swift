import XCTest
@testable import LauncherCore

final class HyperKeyTests: XCTestCase {
    typealias M = HyperMapping
    let control = M.Entry(src: M.capsLock, dst: 0x7_0000_00E0)   // Caps Lock to left Control
    let swap = M.Entry(src: 0x7_0000_0035, dst: 0x7_0000_0064)    // ` to the ISO key

    func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    // MARK: Config

    func testDefaultsAreOff() throws {
        let h = try decode("{}").hyperKey
        XCTAssertFalse(h.enabled, "nothing changes until the user turns it on")
        XCTAssertFalse(h.tapEscape)
        XCTAssertTrue(h.arrowSpaces, "Caps+Left/Right change Spaces unless turned off")
        XCTAssertEqual(h, Config.HyperKey())
    }

    func testConfigKeysAndWrongTypes() throws {
        let h = try decode(#"{"hyperKey": {"enabled": true, "tapEscape": true}}"#).hyperKey
        XCTAssertTrue(h.enabled)
        XCTAssertTrue(h.tapEscape)
        let bad = try decode(#"{"hyperKey": {"enabled": "yes", "tapEscape": 1}, "maxResults": 9}"#)
        XCTAssertEqual(bad.hyperKey, Config.HyperKey())
        XCTAssertEqual(bad.maxResults, 9, "other keys still load")
        XCTAssertEqual(try decode(#"{"hyperKey": true}"#).hyperKey, Config.HyperKey())
        XCTAssertTrue(try decode(#"{"hyperKey": {"enabled": true}}"#).hyperKey.enabled)
    }

    func testRoundTrip() throws {
        var c = Config()
        c.hyperKey.enabled = true
        c.hyperKey.tapEscape = true
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.hyperKey, c.hyperKey)
    }

    func testArrowSpaces() throws {
        XCTAssertFalse(try decode(#"{"hyperKey": {"arrowSpaces": false}}"#).hyperKey.arrowSpaces)
        XCTAssertEqual(M.modifiers(forKeyCode: M.leftArrowKeyCode, arrowSpaces: true), .controlOnly)
        XCTAssertEqual(M.modifiers(forKeyCode: M.rightArrowKeyCode, arrowSpaces: true), .controlOnly)
        XCTAssertEqual(M.modifiers(forKeyCode: 126, arrowSpaces: true), .hyper, "Up stays Hyper")
        XCTAssertEqual(M.modifiers(forKeyCode: 0, arrowSpaces: true), .hyper)
        XCTAssertEqual(M.modifiers(forKeyCode: M.leftArrowKeyCode, arrowSpaces: false), .hyper)
    }

    func testHyperModifierInHotkeys() throws {
        let all = Set(HotKeySpec.Modifier.allCases)
        XCTAssertEqual(try HotKeySpec.parse("hyper+k"), HotKeySpec(modifiers: all, key: .letter("k")))
        XCTAssertEqual(try HotKeySpec.parse("control+option+command+shift+k"), try HotKeySpec.parse("hyper+k"),
                       "a hotkey with all four works with Caps Lock")
        XCTAssertEqual(try HotKeySpec.parse("Hyper+Space").key, .space)
        XCTAssertEqual(try HotKeySpec.parse("hyper+shift+1").modifiers, all)
        XCTAssertThrowsError(try HotKeySpec.parse("hyper"))
        XCTAssertEqual(AutoClickPlan.hotkeyLabel("hyper+k"), "⌃⌥⇧⌘K")
    }

    // MARK: hidutil output

    func testParseNull() {
        XCTAssertEqual(M.parse("(null)\n"), [])
        XCTAssertEqual(M.parse(""), [])
    }

    func testParseHidutilList() {
        let out = """
        (
                {
                HIDKeyboardModifierMappingDst = 30064771181;
                HIDKeyboardModifierMappingSrc = 30064771129;
            },
                {
                HIDKeyboardModifierMappingDst = 30064771172;
                HIDKeyboardModifierMappingSrc = 30064771125;
            }
        )

        """
        XCTAssertEqual(M.parse(out), [M.ours, swap])
        XCTAssertTrue(M.isActive(M.parse(out) ?? []))
        XCTAssertEqual(M.parse("(\n  { HIDKeyboardModifierMappingSrc = 0x700000039; HIDKeyboardModifierMappingDst = 0x70000006D; }\n)"), [M.ours])
    }

    func testParseServiceTable() {
        let table = """
        RegistryID  Key                   Value
        100000890   UserKeyMapping   (null)
        100000cac   UserKeyMapping   (null)

        """
        XCTAssertEqual(M.parse(table), [])
        // An empty list over two lines, next to (null) rows: still no mapping.
        XCTAssertEqual(M.parse("RegistryID  Key                   Value\n100000890   UserKeyMapping   (\n)\n100000cac   UserKeyMapping   (null)\n"), [])
        let ours = "(\n        {\n        HIDKeyboardModifierMappingDst = 30064771181;\n        HIDKeyboardModifierMappingSrc = 30064771129;\n    }\n)"
        XCTAssertEqual(M.parse("RegistryID  Key  Value\n100000890   UserKeyMapping   \(ours)\n100000cac   UserKeyMapping   \(ours)\n"), [M.ours])
        XCTAssertEqual(M.parse("RegistryID  Key  Value\n100000890   UserKeyMapping   \(ours)\n100000cac   UserKeyMapping   (null)\n100000cad   UserKeyMapping   \(ours)\n"),
                       [M.ours], "(null) rows are services without the property")
        XCTAssertNil(M.parse("RegistryID  Key  Value\n100000890   UserKeyMapping   \(ours)\n100000cac   UserKeyMapping   (\n)\n"),
                     "services with different lists are not read")
        XCTAssertNil(M.parse("RegistryID  Key  Value\n100000cac   UserKeyMapping   (\n"), "a broken value is not read")
    }

    func testSystemSettingsCapsLockMapping() {
        // System Settings > Modifier Keys: Caps Lock to Control on the built-in keyboard (0-0-0).
        let prefs: [String: Any] = [
            "com.apple.mouse.tapBehavior": 1,
            "com.apple.keyboard.modifiermapping.0-0-0": [["HIDKeyboardModifierMappingSrc": NSNumber(value: 30064771129 as UInt64),
                                                          "HIDKeyboardModifierMappingDst": NSNumber(value: 30064771300 as UInt64)]],
        ]
        XCTAssertEqual(M.systemSettingsCapsTarget(in: prefs), 30064771300)
        XCTAssertEqual(M.keyName(30064771300), "Control")
        // Caps Lock to Caps Lock, or only other keys mapped: nothing to report.
        let same: [String: Any] = ["com.apple.keyboard.modifiermapping.1452-834-0": [["HIDKeyboardModifierMappingSrc": 30064771129,
                                                                                      "HIDKeyboardModifierMappingDst": 30064771129],
                                                                                     ["HIDKeyboardModifierMappingSrc": 30064771296,
                                                                                      "HIDKeyboardModifierMappingDst": 30064771299]]]
        XCTAssertNil(M.systemSettingsCapsTarget(in: same))
        XCTAssertNil(M.systemSettingsCapsTarget(in: [:]))
    }

    func testParseUnreadableIsNil() {
        XCTAssertNil(M.parse("hidutil: error"))
        XCTAssertNil(M.parse("( { Foo = 1; } )"), "an entry Kea does not understand stops the write")
        XCTAssertNil(M.parse("{ a = b; }"))
    }

    func testUsageNumbers() {
        XCTAssertEqual(M.capsLock, 30064771129)
        XCTAssertEqual(M.f18, 30064771181)
    }

    // MARK: Merge

    func testApplyKeepsOtherMappings() {
        XCTAssertEqual(M.applied(to: []), [M.ours])
        XCTAssertEqual(M.applied(to: [swap]), [swap, M.ours])
        XCTAssertEqual(M.applied(to: [control, swap]), [swap, M.ours], "one mapping per key: Caps Lock to Control goes while Hyper is on")
        XCTAssertEqual(M.applied(to: [swap, M.ours]), [swap, M.ours], "applying again adds no second entry")
    }

    func testRemoveRestoresTheOriginal() {
        XCTAssertEqual(M.foreignCapsEntry(in: [swap, control]), control)
        XCTAssertNil(M.foreignCapsEntry(in: [swap, M.ours]))
        XCTAssertEqual(M.removed(from: [swap, M.ours], restoring: nil), [swap])
        XCTAssertEqual(M.removed(from: [swap, M.ours], restoring: control), [swap, control])
        XCTAssertEqual(M.removed(from: [M.ours], restoring: nil), [])
        XCTAssertEqual(M.removed(from: [swap, control], restoring: control), [swap, control],
                       "someone set Caps Lock again while Hyper was on: keep theirs")
        // The whole path: the user has Caps Lock to Control, Hyper turns on, then off.
        let before = [control, swap]
        let on = M.applied(to: before)
        XCTAssertEqual(Set(M.removed(from: on, restoring: M.foreignCapsEntry(in: before)).map(\.src)), Set(before.map(\.src)))
    }

    func testJSON() throws {
        XCTAssertEqual(M.json([]), #"{"UserKeyMapping":[]}"#)
        let text = M.json([M.ours])
        XCTAssertEqual(text, #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":30064771129,"HIDKeyboardModifierMappingDst":30064771181}]}"#)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(M.json([swap, M.ours]).utf8)) as? [String: [[String: UInt64]]])
        XCTAssertEqual(obj["UserKeyMapping"]?.count, 2)
        XCTAssertEqual(obj["UserKeyMapping"]?[1]["HIDKeyboardModifierMappingDst"], M.f18)
    }

    // MARK: Held state

    func testHoldAddsHyperToOtherKeys() {
        var s = HyperState()
        XCTAssertFalse(s.otherInput(), "no Hyper before Caps Lock")
        s.hyperDown(at: 0)
        XCTAssertTrue(s.isHeld)
        XCTAssertTrue(s.otherInput())
        XCTAssertTrue(s.otherInput())
        XCTAssertEqual(s.hyperUp(at: 0.2), .none)
        XCTAssertFalse(s.isHeld)
        XCTAssertFalse(s.otherInput())
    }

    func testTapEscapeOffByDefault() {
        var s = HyperState()
        s.hyperDown(at: 0)
        XCTAssertEqual(s.hyperUp(at: 0.1), .none)
    }

    func testTapSendsEscape() {
        var s = HyperState(tapEscape: true)
        s.hyperDown(at: 10)
        XCTAssertEqual(s.hyperUp(at: 10.1), .escape)
        s.hyperDown(at: 11)
        XCTAssertEqual(s.hyperUp(at: 11 + HyperState.tapLimit), .escape, "the limit itself still counts")
    }

    func testNoEscapeAfterAKeyOrALongHold() {
        var s = HyperState(tapEscape: true)
        s.hyperDown(at: 0)
        _ = s.otherInput()
        XCTAssertEqual(s.hyperUp(at: 0.1), .none, "Caps+K is a chord, not a tap")
        s.hyperDown(at: 1)
        XCTAssertEqual(s.hyperUp(at: 1.6), .none, "held too long")
        s.hyperDown(at: 2)
        XCTAssertEqual(s.hyperUp(at: 2.1), .escape, "used is cleared at the next press")
    }

    func testKeyRepeatDoesNotRestartTheTimer() {
        var s = HyperState(tapEscape: true)
        s.hyperDown(at: 0)
        s.hyperDown(at: 0.45)
        s.hyperDown(at: 0.9)
        XCTAssertEqual(s.hyperUp(at: 1.0), .none, "repeat downs keep the first time")
    }

    func testUpWithoutDownAndReset() {
        var s = HyperState(tapEscape: true)
        XCTAssertEqual(s.hyperUp(at: 0), .none)
        s.hyperDown(at: 0)
        s.reset()
        XCTAssertFalse(s.isHeld)
        XCTAssertEqual(s.hyperUp(at: 0.1), .none, "a reset is not a tap")
    }
}
