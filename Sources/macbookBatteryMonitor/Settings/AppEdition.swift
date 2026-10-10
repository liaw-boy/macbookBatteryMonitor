import Foundation

/// 每次發布都編出兩個版本讓使用者選：
/// - 電池版（battery）：只有電池資訊
/// - 系統監控版（status）：另外有 CPU／GPU、記憶體、磁碟、網路模組
/// build.sh 把版本寫進 Info.plist 的 MBMEdition；直接執行未打包的執行檔（開發時）視為系統監控版
enum AppEdition: String {
    case battery
    case status

    static let current: AppEdition = {
        (Bundle.main.object(forInfoDictionaryKey: "MBMEdition") as? String).flatMap(AppEdition.init(rawValue:)) ?? .status
    }()

    var hasSystemMonitors: Bool { self == .status }

    var title: String {
        switch self {
        case .battery: return "電池版"
        case .status: return "系統監控版"
        }
    }
}
