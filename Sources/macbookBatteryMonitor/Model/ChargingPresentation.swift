import Foundation

/// 只穩定顯示狀態，不修改原始旗標、電流或功率。
struct ChargingPresentation {
    private var displayed: PowerState?
    private var fullLatched = false
    private var pending: (state: PowerState, since: TimeInterval)?
    private var lastLimit: Int?
    var hasReachedFull: Bool { fullLatched }

    mutating func state(_ snapshot: BatterySnapshot, uptime: TimeInterval) -> PowerState {
        let raw = Estimator.state(snapshot)
        guard snapshot.externalConnected else {
            self = ChargingPresentation()
            displayed = .discharging
            return .discharging
        }
        let limit = snapshot.chargeLimit?.limit
        if limit != lastLimit {
            self = ChargingPresentation()
            lastLimit = limit
        }
        // 系統充電上限與降到上限的策略優先，不套用 100% 滿電緩衝。
        if limit != nil {
            fullLatched = false; pending = nil; displayed = raw
            return raw
        }
        if snapshot.percent >= 100 || (snapshot.fullyCharged && snapshot.percent >= 98) {
            fullLatched = true; pending = nil; displayed = .full
            return .full
        }
        if fullLatched && snapshot.percent < 98 {
            fullLatched = false; pending = nil; displayed = raw
            return raw
        }
        let candidate: PowerState = fullLatched && !snapshot.isCharging  ? .full : raw
        // 第一次讀取、實際插拔電源立即顯示；接電中的旗標變化才確認 10 秒。
        guard let previous = displayed, previous != .discharging else {
            displayed = candidate; pending = nil
            return candidate
        }
        guard candidate != previous else {
            pending = nil
            return previous
        }
        if let pending, pending.state == candidate,
           uptime - pending.since >= 10 {
            displayed = candidate
            self.pending = nil
            return candidate
        }
        if pending?.state != candidate { pending = (candidate, uptime) }
        return previous
    }
}

enum PowerFlowKind: String, Codable { case battery, adapter, charging, mixed }

/// 電量狀態與供電方向分開：滿電時的小幅電池補電不改變圖的拓樸。
struct PowerFlowPresentation {
    private var displayed: PowerFlowKind?
    private var pending: (kind: PowerFlowKind, since: TimeInterval)?

    static func rawKind(connected: Bool, watts: Double, nearFull: Bool) -> PowerFlowKind {
        guard connected else { return .battery }
        let threshold = nearFull ? 2.0 : 0.05
        if watts > threshold { return .charging }
        if watts < -threshold { return .mixed }
        return .adapter
    }

    mutating func kind(connected: Bool, watts: Double, nearFull: Bool, uptime: TimeInterval) -> PowerFlowKind {
        let candidate = Self.rawKind(connected: connected, watts: watts, nearFull: nearFull)
        guard nearFull, connected else {
            displayed = candidate; pending = nil
            return candidate
        }
        // 初次開啟或滿電重新插電也先確認，避免第一筆功率差尖峰切換圖形。
        let previous = displayed == .battery ? .adapter : (displayed ?? .adapter)
        displayed = previous
        guard previous != candidate else {
            pending = nil
            return previous
        }
        if let pending, pending.kind == candidate, uptime - pending.since >= 10 {
            displayed = candidate; self.pending = nil
            return candidate
        }
        if pending?.kind != candidate { pending = (candidate, uptime) }
        return previous
    }
}

extension Estimates {
    var flowKind: PowerFlowKind {
        displayFlow ?? PowerFlowPresentation.rawKind(connected: state != .discharging,
                                                    watts: batteryWatts, nearFull: state == .full)
    }
}
