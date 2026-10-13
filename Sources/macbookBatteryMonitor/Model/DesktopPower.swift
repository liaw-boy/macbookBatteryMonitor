import Foundation

/// 桌上型 Mac（Mac mini、iMac、Mac Studio 等，沒有電池）的電源資訊
struct DesktopPower: Equatable {
    var date: Date
    /// 整機耗電（SMC PSTR）；讀不到時為 nil
    var systemWatts: Double?
    /// 近 3 分鐘平均（與 MacBook 的平均放電同樣的時間常數）
    var averageWatts: Double?
    var lowPowerMode = false
    /// 例如 "Apple M2 Pro"、"Intel Core i5-8500B"
    var processor = ""
    /// 機型代號，例如 "Macmini8,1"
    var model = ""
    /// 開機多久（秒）
    var uptime: TimeInterval = 0
    /// iMac 有內建螢幕：沒有背光感測器時，「其他」包含螢幕；Mac mini 這類沒有
    var hasBuiltInDisplay = false
}
