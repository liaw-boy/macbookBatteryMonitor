import Foundation

public enum CPUHelperConstants {
    public static let label = "com.kuan.batterymonitor.cpu"
    public static let directory = "/Library/PrivilegedHelperTools/com.kuan.batterymonitor.cpu"
    public static let executable = directory + "/CPUPowerHelper"
    public static let configuration = directory + "/config.json"
    public static let launchDaemon = "/Library/LaunchDaemons/" + label + ".plist"
    /// 通訊協定改變時加一；舊版服務會被視為未安裝，需要重新授權
    public static let version = 2
    /// 沒有任何取樣租約多久後服務自行結束（launchd 會在下次連線時再啟動）
    public static let idleExit: TimeInterval = 30

    /// 只接受 1 秒（一般）或 2 秒（省電模式）兩種取樣間隔
    public static func samplingInterval(_ requested: Int) -> Int { requested >= 2 ? 2 : 1 }
}

public struct CPUHelperConfiguration: Codable {
    public let uid: UInt32
    public let version: Int
    public init(uid: UInt32) { self.uid = uid; version = CPUHelperConstants.version }
}

public struct CPUHelperReply: Codable {
    public let version: Int
    public let reading: CPUPowerReading?
    public let error: String?
    public init(reading: CPUPowerReading?, error: String? = nil) {
        version = CPUHelperConstants.version
        self.reading = reading
        self.error = error
    }
}

/// 不接受指令、路徑或 PID；取樣間隔只能是 1 或 2 秒。唯一高權限工作是固定的 CPU 功耗讀取。
@objc public protocol CPUHelperProtocol {
    func sample(active: Bool, interval: Int, withReply reply: @escaping (Data) -> Void)
    func uninstall(withReply reply: @escaping (String?) -> Void)
}
