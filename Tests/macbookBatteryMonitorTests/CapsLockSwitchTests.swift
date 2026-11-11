import Foundation

struct CapsLockSwitchTests {
    private func output(_ pairs: [(UInt64, UInt64)]) -> String {
        "RegistryID  Key                   Value\n" + pairs.enumerated().map { index, pair in
            """
            1000005d\(index)   UserKeyMapping   (
                    {
                    HIDKeyboardModifierMappingDst = \(pair.1);
                    HIDKeyboardModifierMappingSrc = \(pair.0);
                }
            )
            """
        }.joined(separator: "\n")
    }

    /// 只有我們的對應、沒有對應、別人的對應，三種情況分得出來
    func testDetectsMappings() {
        let ours = (CapsLockSwitch.capsLockUsage, CapsLockSwitch.f18Usage)
        let empty = "RegistryID  Key                   Value\n1000005df   UserKeyMapping   (\n)\n100000b1d   UserKeyMapping   (null)"
        XCTAssertTrue(!CapsLockSwitch.hasForeignMapping(hidutilOutput: empty))
        XCTAssertTrue(!CapsLockSwitch.hasOnlyOurMapping(hidutilOutput: empty))
        XCTAssertTrue(!CapsLockSwitch.hasForeignMapping(hidutilOutput: output([ours, ours])))
        XCTAssertTrue(CapsLockSwitch.hasOnlyOurMapping(hidutilOutput: output([ours, ours])))
        // 使用者自己把 Caps Lock 對應成 Escape：不能蓋掉
        let escape = (CapsLockSwitch.capsLockUsage, UInt64(0x7_0000_0029))
        XCTAssertTrue(CapsLockSwitch.hasForeignMapping(hidutilOutput: output([escape])))
        XCTAssertTrue(!CapsLockSwitch.hasOnlyOurMapping(hidutilOutput: output([ours, escape])))
        XCTAssertTrue(CapsLockSwitch.hasForeignMapping(hidutilOutput: output([ours, escape])))
    }

    /// 寫給 hidutil 的 JSON 用十進位，對應的就是 Caps Lock → F18
    func testMappingJSON() {
        XCTAssertTrue(CapsLockSwitch.mappingJSON.contains("\"HIDKeyboardModifierMappingSrc\":30064771129"))
        XCTAssertTrue(CapsLockSwitch.mappingJSON.contains("\"HIDKeyboardModifierMappingDst\":30064771181"))
    }

    /// 短按切到另一邊；長按：沒開大寫 → 打開並用英文，開著 → 關掉並回到按下前的輸入法
    func testPressAndLongPress() {
        XCTAssertEqual(CapsLockSwitch.target(currentIsEnglish: true), .chinese)
        XCTAssertEqual(CapsLockSwitch.target(currentIsEnglish: false), .english)
        let turnOn = CapsLockSwitch.longPress(capsLockOn: false)
        XCTAssertTrue(turnOn.capsLock)
        XCTAssertEqual(turnOn.source, .english)
        let turnOff = CapsLockSwitch.longPress(capsLockOn: true)
        XCTAssertTrue(!turnOff.capsLock)
        XCTAssertNil(turnOff.source)
    }

    func testHoldIsClamped() {
        XCTAssertEqual(CapsLockSwitch.clampHold(0.5), 0.5)
        XCTAssertEqual(CapsLockSwitch.clampHold(0.01), 0.3)
        XCTAssertEqual(CapsLockSwitch.clampHold(9), 1.5)
        XCTAssertEqual(CapsLockSwitch.clampHold(.nan), CapsLockSwitch.defaultHold)
    }
}
