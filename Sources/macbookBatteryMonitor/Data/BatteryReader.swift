import Foundation
import IOKit
import IOKit.ps

struct AdapterInfo: Codable, Equatable {
    var watts: Int?
    var voltage_mV: Int?
    var current_mA: Int?
    var name: String?
}

/// 某一時間點讀到的原始電池資料。時間單位都是分鐘，nil 代表系統沒提供或還在計算。
struct BatterySnapshot: Codable, Equatable {
    var date = Date()
    var percent = 0
    var isCharging = false
    var externalConnected = false
    var fullyCharged = false
    var voltage_mV = 0
    /// 負值代表放電
    var amperage_mA = 0
    var cycleCount = 0
    var designCycleCount: Int?
    var remaining_mAh: Int?
    var fullCharge_mAh: Int?
    var nominal_mAh: Int?
    var design_mAh: Int?
    var avgTimeToEmpty: Int?
    var avgTimeToFull: Int?
    var psTimeToEmpty: Int?
    var psTimeToFull: Int?
    var temperature_C: Double?
    var notChargingReason: Int?
    var adapter: AdapterInfo?
    var systemLoad_mW: Int?
    var systemPowerIn_mW: Int?
    var lowPowerMode = false
    var serial: String?
    /// 系統設定的充電上限（沒設定時為 nil）
    var chargeLimit: ChargeLimit?

    var smcBatteryWatts: Double?
    var smcAdapterWatts: Double?
    var smcSystemWatts: Double?

    /// 電池功率（W，正值充入、負值放出），用同次 SMC 輸入與系統功率推算。
    /// 缺少任一路時退回 Registry 電壓 × 電流，不使用不可靠的 PPBR。
    var liveBatteryWatts: Double? {
        guard let system = smcSystemWatts else { return nil }
        if !externalConnected { return -system }
        guard let input = smcAdapterWatts else { return nil }
        return input - system
    }

    /// 是否正在充電。電池晶片的 IsCharging 會停在舊值：實測 M1 接著電源、SMC 顯示約 14 W 充入電池、電量持續上升時，
    /// 仍有十幾秒回報「未充電、電流 0」。有 SMC 即時功率時以功率為準，只有數值落在模糊區間才看晶片旗標。
    var chargingNow: Bool {
        guard externalConnected else { return false }
        guard let watts = liveBatteryWatts else { return isCharging }
        if watts >= 3 { return true }
        if watts < 0.5 { return false }
        return isCharging
    }

    /// 電量高於充電上限、電池正在放電到上限（與「供電不足」相同，以 -50 mA 為門檻，避免雜訊）
    var drainingAboveLimit: Bool {
        guard let limit = chargeLimit?.limit else { return false }
        return percent > limit && effectiveAmperage_mA < -50
    }

    /// 電量高於系統充電上限、macOS 暫停變壓器供電讓電池放電到上限（生效中的策略只在接電時存在）
    var drainingToChargeLimit: Bool {
        guard let limit = chargeLimit, limit.active else { return false }
        return percent >= limit.limit - 1
    }

    /// SMC 功率換算的近似電流；原始 Registry 電流保留供診斷。
    var effectiveAmperage_mA: Int {
        guard let watts = liveBatteryWatts, voltage_mV > 0 else { return amperage_mA }
        if !externalConnected, watts > 0 { return min(0, amperage_mA) }
        return Int((watts * 1_000_000 / Double(voltage_mV)).rounded())
    }

    mutating func applyLivePower(battery: Double?, adapter: Double?, system: Double?) {
        func valid(_ value: Double?, signed: Bool = false) -> Double? {
            guard let value, value.isFinite, abs(value) < 500, signed || value >= 0 else { return nil }
            return value
        }
        smcBatteryWatts = valid(battery, signed: true)
        smcAdapterWatts = valid(adapter)
        smcSystemWatts = valid(system)
    }

    /// AC／滿電旗標可能在停止供電後仍保留；只在有明確零輸入且放電時覆寫。
    mutating func reconcilePowerSource(inputMilliwatts: Int?) {
        if externalConnected, let input = smcAdapterWatts, input > 0.5 {
            // 已接上時，SMC 可排除 Registry 零輸入的延遲；不覆寫明確的拔除狀態。
        } else if externalConnected, drainingToChargeLimit {
            // 放電到充電上限時變壓器暫停供電，但線仍接著，不視為拔除。
        } else if !isCharging, effectiveAmperage_mA < -50,
                  (smcAdapterWatts.map { $0 <= 0.5 } ?? (inputMilliwatts == 0)) {
            externalConnected = false
        }
        if !externalConnected {
            isCharging = false
            adapter = nil
            systemPowerIn_mW = nil
        }
    }
}

enum BatteryReader {
    private static let smc = SMC()

    static func read(includeTemperature: Bool = true, includeLivePower: Bool = true) -> BatterySnapshot? {
        guard let reg = registryProperties() else { return nil }
        let data = reg["BatteryData"] as? [String: Any] ?? [:]
        let telemetry = reg["PowerTelemetryData"] as? [String: Any] ?? [:]
        let charger = reg["ChargerData"] as? [String: Any] ?? [:]
        let ps = internalBatteryDescription() ?? [:]

        // 新舊系統的 key 位置不同：有的在頂層，有的在 BatteryData 裡
        func lookup(_ keys: String...) -> Int? {
            for key in keys {
                if let v = int(reg[key]) ?? int(data[key]) { return v }
            }
            return nil
        }

        var s = BatterySnapshot()
        if let cur = int(ps["Current Capacity"]), let max = int(ps["Max Capacity"]), max > 0 {
            s.percent = cur * 100 / max
        } else if let cur = int(reg["CurrentCapacity"]), let max = int(reg["MaxCapacity"]), max > 0 {
            s.percent = cur * 100 / max
        }
        s.isCharging = bool(ps["Is Charging"]) ?? bool(reg["IsCharging"]) ?? false
        if let connected = bool(reg["ExternalConnected"]) {
            s.externalConnected = connected
        } else if let state = ps["Power Source State"] as? String {
            s.externalConnected = state == "AC Power"
        } else {
            s.externalConnected = bool(reg["ExternalConnected"]) ?? false
        }
        s.fullyCharged = bool(reg["FullyCharged"]) ?? bool(ps["Is Charged"]) ?? false
        s.voltage_mV = int(reg["Voltage"]) ?? int(reg["AppleRawBatteryVoltage"]) ?? 0
        s.amperage_mA = int(reg["Amperage"]) ?? int(reg["InstantAmperage"]) ?? 0
        s.cycleCount = int(reg["CycleCount"]) ?? 0
        s.designCycleCount = int(reg["DesignCycleCount9C"]) ?? int(reg["DesignCycleCount"])
        s.remaining_mAh = lookup("AppleRawCurrentCapacity", "RemainingCapacity")
        s.fullCharge_mAh = lookup("AppleRawMaxCapacity", "FullChargeCapacity")
        s.nominal_mAh = lookup("NominalChargeCapacity")
        s.design_mAh = lookup("DesignCapacity")
        s.avgTimeToEmpty = validMinutes(int(reg["AvgTimeToEmpty"]))
        s.avgTimeToFull = validMinutes(int(reg["AvgTimeToFull"]))
        s.psTimeToEmpty = validMinutes(int(ps["Time to Empty"]))
        s.psTimeToFull = validMinutes(int(ps["Time to Full Charge"]))
        s.notChargingReason = int(charger["NotChargingReason"]) ?? int(reg["NotChargingReason"])
        s.systemLoad_mW = positive(int(telemetry["SystemLoad"]))
        s.systemPowerIn_mW = positive(int(telemetry["SystemPowerIn"]))
        if includeLivePower {
            // 電池功率由 PDTR − PSTR 推算，不使用 PPBR（見 liveBatteryWatts），所以不必讀
            s.applyLivePower(battery: nil, adapter: smc?.read("PDTR"), system: smc?.read("PSTR"))
        }
        s.chargeLimit = ChargeLimitReader.current()
        s.reconcilePowerSource(inputMilliwatts: int(telemetry["SystemPowerIn"]))
        s.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        s.serial = reg["Serial"] as? String

        if let t = int(reg["Temperature"]) ?? int(data["Temperature"]) ?? int(reg["VirtualTemperature"]), t > 0 {
            s.temperature_C = Double(t) / 100
        } else if includeTemperature {
            s.temperature_C = smc?.batteryTemperature()
        }

        if s.externalConnected {
            s.adapter = adapterInfo()
        } else {
            adapterCache = nil
        }
        return s
    }

    /// 只讀 PowerTelemetryData 的 SystemLoad（W）。不碰任何共用快取，可以在背景執行緒呼叫
    static func systemLoadWatts() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let telemetry = IORegistryEntryCreateCFProperty(service, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
              let load = (telemetry["SystemLoad"] as? NSNumber)?.int64Value, load > 0 else { return nil }
        return Double(load) / 1000
    }

    /// 變壓器規格（額定瓦數等）不會每秒變；接上電源後先查一次，之後每 30 秒更新
    private static var adapterCache: (info: AdapterInfo?, date: Date)?

    private static func adapterInfo() -> AdapterInfo? {
        if let cache = adapterCache, Date().timeIntervalSince(cache.date) < 30 { return cache.info }
        var info: AdapterInfo?
        if let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            info = AdapterInfo(
                watts: int(details["Watts"]),
                voltage_mV: int(details["AdapterVoltage"]) ?? int(details["Voltage"]),
                current_mA: int(details["Current"]),
                name: (details["Name"] as? String) ?? (details["Description"] as? String)
            )
        }
        adapterCache = (info, Date())
        return info
    }

    private static func registryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return dict
    }

    private static func internalBatteryDescription() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if desc["Type"] as? String == "InternalBattery" { return desc }
        }
        return nil
    }

    /// 負數會以 64-bit 補數存在 registry 裡，用 int64Value 取回帶正負號的值
    private static func int(_ any: Any?) -> Int? {
        guard let n = any as? NSNumber else { return nil }
        return Int(truncatingIfNeeded: n.int64Value)
    }

    private static func bool(_ any: Any?) -> Bool? {
        (any as? NSNumber)?.boolValue
    }

    private static func validMinutes(_ v: Int?) -> Int? {
        guard let v, v > 0, v < 65535 else { return nil }
        return v
    }

    private static func positive(_ v: Int?) -> Int? {
        guard let v, v > 0 else { return nil }
        return v
    }
}
