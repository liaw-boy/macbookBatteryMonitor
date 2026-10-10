import Foundation

public enum CPUHelperConstants {
    public static let label = "com.kuan.batterymonitor.cpu"
    public static let directory = "/Library/PrivilegedHelperTools/com.kuan.batterymonitor.cpu"
    public static let executable = directory + "/CPUPowerHelper"
    public static let configuration = directory + "/config.json"
    public static let launchDaemon = "/Library/LaunchDaemons/" + label + ".plist"
    public static let version = 1
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

/// 不接受指令、路徑、PID 或取樣頻率；唯一高權限工作是固定的 CPU 功耗讀取。
@objc public protocol CPUHelperProtocol {
    func sample(active: Bool, withReply reply: @escaping (Data) -> Void)
    func uninstall(withReply reply: @escaping (String?) -> Void)
}
