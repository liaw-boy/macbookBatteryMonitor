import Foundation

public struct CPUPowerReading: Codable {
    public let watts: Double
    public let uptime: TimeInterval
    public init(watts: Double, uptime: TimeInterval) { self.watts = watts; self.uptime = uptime }
    /// maxAge：取樣間隔 1 秒時為 3 秒，省電模式（2 秒）時放寬
    public func freshWatts(at now: TimeInterval, maxAge: TimeInterval = 3) -> Double? {
        guard watts.isFinite, watts >= 0, watts < 500,
              (0...maxAge).contains(now - uptime) else { return nil }
        return watts
    }
}

/// 每個連線只擁有自己的取樣租約；暫停一個連線不會打斷其他連線。
public struct CPUSamplingLeases {
    private var clients: [UUID: (start: TimeInterval, duration: TimeInterval)] = [:]
    public init() {}
    /// duration：租約有效時間，更新頻率較慢時要拉長（見 CPUHelperConstants.leaseDuration）
    public mutating func set(_ client: UUID, active: Bool, at now: TimeInterval, duration: TimeInterval = 5) {
        if active { clients[client] = (now, duration) } else { clients.removeValue(forKey: client) }
    }
    public mutating func remove(_ client: UUID) { clients.removeValue(forKey: client) }
    public func isActive(at now: TimeInterval) -> Bool {
        clients.values.contains { (0..<$0.duration).contains(now - $0.start) }
    }
}
