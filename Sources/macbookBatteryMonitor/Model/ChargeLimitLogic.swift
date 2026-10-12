import Foundation

/// 充電上限滑桿的純邏輯（不碰系統服務，方便測試）
enum ChargeLimitLogic {
    /// 系統設定提供的級距（80–100%，每 5%）；系統沒回傳時用這組
    static let defaultOptions = [80, 85, 90, 95, 100]

    /// 整理系統回傳的可選上限：只留 50–100 的整數、去重排序，而且一定要有 100（不限制）；不合理就用預設級距
    static func options(from raw: [Any]?) -> [Int] {
        let values = Set((raw ?? []).compactMap { ($0 as? NSNumber)?.intValue }).filter { (50...100).contains($0) }
        let sorted = values.sorted()
        guard sorted.count >= 2, sorted.last == 100 else { return defaultOptions }
        return sorted
    }

    /// 系統回報的上限；超出 50–100（例如從沒設定過時的 0）視為不限制
    static func normalized(_ raw: Int) -> Int {
        (50...100).contains(raw) ? raw : 100
    }

    /// 上限 → 滑桿上最接近的格子
    static func index(of limit: Int, in options: [Int]) -> Int {
        options.indices.min { abs(options[$0] - limit) < abs(options[$1] - limit) } ?? 0
    }

    /// 滑桿位置（第幾格）→ 上限
    static func limit(atIndex position: Double, in options: [Int]) -> Int? {
        guard !options.isEmpty, position.isFinite else { return nil }
        return options[min(max(Int(position.rounded()), 0), options.count - 1)]
    }
}
