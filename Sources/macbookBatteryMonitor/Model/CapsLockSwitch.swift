/// Caps Lock 按下就切換中英（實驗）。
/// 系統的「用大寫鎖定鍵切換輸入法」要放開才切換：打字快時，還沒放開就按下一個字，那個字會進舊的輸入法。
/// 做法：用 hidutil 把 Caps Lock 對應成 F18（系統不再把它當 Caps Lock），App 收到 F18 按下就切換；
/// 按住超過門檻改成切換大寫鎖定，和系統原本「長按大寫」的習慣一樣
enum CapsLockSwitch {
    /// hidutil 的 HID 用法碼：鍵盤頁（0x7）的 Caps Lock、F18
    static let capsLockUsage: UInt64 = 0x7_0000_0039
    static let f18Usage: UInt64 = 0x7_0000_006D
    /// F18 的虛擬鍵碼（kVK_F18）
    static let f18KeyCode: Int64 = 79

    static let defaultHold = 0.5
    static let holdRange = 0.3...1.5
    static func clampHold(_ seconds: Double) -> Double {
        seconds.isFinite ? min(max(seconds, holdRange.lowerBound), holdRange.upperBound) : defaultHold
    }

    static var mappingJSON: String {
        #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":\#(capsLockUsage),"HIDKeyboardModifierMappingDst":\#(f18Usage)}]}"#
    }
    static let clearJSON = #"{"UserKeyMapping":[]}"#

    /// `hidutil property --get UserKeyMapping` 的輸出裡有沒有別人的鍵位對應（hidutil 一次設定會整個取代，不能蓋掉）
    static func hasForeignMapping(hidutilOutput: String) -> Bool {
        mappings(in: hidutilOutput).contains { $0 != (capsLockUsage, f18Usage) }
    }

    /// 輸出裡是不是只有我們的對應（例如上次當掉沒還原）
    static func hasOnlyOurMapping(hidutilOutput: String) -> Bool {
        let found = mappings(in: hidutilOutput)
        return !found.isEmpty && found.allSatisfy { $0 == (capsLockUsage, f18Usage) }
    }

    /// 依序取出每一組 Src / Dst（hidutil 以十進位印出）
    private static func mappings(in output: String) -> [(UInt64, UInt64)] {
        func values(_ key: String) -> [UInt64] {
            output.components(separatedBy: key).dropFirst().compactMap { part in
                UInt64(part.drop { !$0.isNumber }.prefix { $0.isNumber })
            }
        }
        return Array(zip(values("HIDKeyboardModifierMappingSrc"), values("HIDKeyboardModifierMappingDst")))
    }

    enum Target: Equatable { case english, chinese }

    /// 按下：英文切中文、中文切英文
    static func target(currentIsEnglish: Bool) -> Target { currentIsEnglish ? .chinese : .english }

    /// 按住超過門檻：大寫鎖定沒開 → 打開並用英文；開著 → 關掉並回到按下前的輸入法（nil）
    static func longPress(capsLockOn: Bool) -> (capsLock: Bool, source: Target?) {
        capsLockOn ? (false, nil) : (true, .english)
    }
}
