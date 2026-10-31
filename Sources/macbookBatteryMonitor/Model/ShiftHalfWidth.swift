/// 中文輸入法（例如內建注音）按住 Shift 打字母或數字那排會打出全形英文「Ａ」、全形符號「！」。這裡決定什麼時候暫時切到英文鍵盤：
/// 按住 Shift 打第一個字母或數字那排時切過去（這個字就打成半形），放開 Shift 時切回原本的輸入法。
/// 只做判斷，切換與事件攔截在 InputSourceFix
struct ShiftHalfWidth {
    enum Event {
        case keyDown(keyCode: Int, shift: Bool, otherModifiers: Bool)
        case shiftReleased
    }

    enum Action: Equatable { case pass, switchToASCII, restore }

    /// 美式鍵盤 A～Z 的虛擬按鍵碼
    static let letterKeyCodes: Set<Int> = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17,
                                           31, 32, 34, 35, 37, 38, 40, 45, 46]
    /// 數字那排 1～0、-、=（Shift 時是 !@#$%^&*()_+）
    static let numberRowKeyCodes: Set<Int> = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]
    /// Shift + 這些鍵才處理。逗號、句號等標點不動：注音用 Shift 打「，」「。」
    static let switchKeyCodes = letterKeyCodes.union(numberRowKeyCodes)

    /// 只對中文輸入法生效：不能直接打 ASCII、而且主要語言是中文。俄文、韓文、日文等鍵盤不處理
    static func isChineseInputMethod(languages: [String], asciiCapable: Bool) -> Bool {
        !asciiCapable && (languages.first?.hasPrefix("zh") ?? false)
    }

    /// 已經暫時切到英文鍵盤，放開 Shift 時要切回去
    private(set) var switched = false

    /// imeActive：目前是中文輸入法（見 isChineseInputMethod）
    mutating func handle(_ event: Event, imeActive: Bool) -> Action {
        switch event {
        case let .keyDown(keyCode, shift, otherModifiers):
            // 保險：漏掉放開 Shift 的事件（例如攔截剛好被系統暫停）時，不按 Shift 的下一個鍵就切回去，不會一直卡在英文
            if switched, !shift {
                switched = false
                return .restore
            }
            guard !switched, imeActive, shift, !otherModifiers, Self.switchKeyCodes.contains(keyCode) else { return .pass }
            switched = true
            return .switchToASCII
        case .shiftReleased:
            guard switched else { return .pass }
            switched = false
            return .restore
        }
    }
}
