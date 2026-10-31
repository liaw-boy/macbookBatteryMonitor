import Foundation

final class ShiftHalfWidthTests {
    private let a = 0, one = 18, equals = 24, space = 49, comma = 43

    func testShiftLetterSwitchesOnceAndRestoresOnRelease() {
        var logic = ShiftHalfWidth()
        XCTAssertEqual(logic.handle(.keyDown(keyCode: a, shift: true, otherModifiers: false), imeActive: true), .switchToASCII)
        // 還按著 Shift 的下一個字母：已經是英文鍵盤，不再切
        XCTAssertEqual(logic.handle(.keyDown(keyCode: a, shift: true, otherModifiers: false), imeActive: false), .pass)
        XCTAssertEqual(logic.handle(.shiftReleased, imeActive: false), .restore)
        XCTAssertEqual(logic.handle(.shiftReleased, imeActive: true), .pass)
    }

    func testLeavesOtherKeysAlone() {
        var logic = ShiftHalfWidth()
        // 沒按 Shift、空白、逗號（注音用 Shift 打「，」）、Cmd/Ctrl/Option 組合、非中文輸入法：都不切
        XCTAssertEqual(logic.handle(.keyDown(keyCode: a, shift: false, otherModifiers: false), imeActive: true), .pass)
        XCTAssertEqual(logic.handle(.keyDown(keyCode: comma, shift: true, otherModifiers: false), imeActive: true), .pass)
        XCTAssertEqual(logic.handle(.keyDown(keyCode: space, shift: true, otherModifiers: false), imeActive: true), .pass)
        XCTAssertEqual(logic.handle(.keyDown(keyCode: a, shift: true, otherModifiers: true), imeActive: true), .pass)
        XCTAssertEqual(logic.handle(.keyDown(keyCode: a, shift: true, otherModifiers: false), imeActive: false), .pass)
        // 只按 Shift 放開（切換大小寫、選字）：沒切過就不切回
        XCTAssertEqual(logic.handle(.shiftReleased, imeActive: true), .pass)
        XCTAssertEqual(logic.switched, false)
    }

    func testMissedShiftReleaseRestoresOnNextUnshiftedKey() {
        var logic = ShiftHalfWidth()
        XCTAssertEqual(logic.handle(.keyDown(keyCode: a, shift: true, otherModifiers: false), imeActive: true), .switchToASCII)
        XCTAssertEqual(logic.handle(.keyDown(keyCode: a, shift: false, otherModifiers: false), imeActive: false), .restore)
        XCTAssertEqual(logic.switched, false)
    }

    /// 數字那排（!@#$%^&*()_+）也切到英文，打出半形符號
    func testNumberRowSwitchesToo() {
        var logic = ShiftHalfWidth()
        XCTAssertEqual(logic.handle(.keyDown(keyCode: one, shift: true, otherModifiers: false), imeActive: true), .switchToASCII)
        XCTAssertEqual(logic.handle(.shiftReleased, imeActive: false), .restore)
        XCTAssertEqual(logic.handle(.keyDown(keyCode: equals, shift: true, otherModifiers: false), imeActive: true), .switchToASCII)
    }

    /// 只有中文輸入法算：俄文、韓文、日文、英文鍵盤都不處理
    func testOnlyChineseInputMethods() {
        XCTAssertTrue(ShiftHalfWidth.isChineseInputMethod(languages: ["zh-Hant"], asciiCapable: false))
        XCTAssertTrue(ShiftHalfWidth.isChineseInputMethod(languages: ["zh-Hans", "en"], asciiCapable: false))
        XCTAssertTrue(!ShiftHalfWidth.isChineseInputMethod(languages: ["ru"], asciiCapable: false))
        XCTAssertTrue(!ShiftHalfWidth.isChineseInputMethod(languages: ["ko"], asciiCapable: false))
        XCTAssertTrue(!ShiftHalfWidth.isChineseInputMethod(languages: ["ja"], asciiCapable: false))
        XCTAssertTrue(!ShiftHalfWidth.isChineseInputMethod(languages: ["zh-Hant"], asciiCapable: true))
        XCTAssertTrue(!ShiftHalfWidth.isChineseInputMethod(languages: [], asciiCapable: false))
    }
}
