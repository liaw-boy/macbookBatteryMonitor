import Foundation

final class HardwarePowerReader {
    private let report = IOReportReader()
    private let smc = SMC()
    /// 有沒有螢幕背光功率感測器（例如 M1 MacBook Air 沒有 PDBR／PBwo）；沒有就不顯示背光，其他功耗改為包含螢幕
    private lazy var backlightAvailable = smc.map { $0.hasKey("PDBR") || $0.hasKey("PBwo") } ?? false
    /// Intel Mac 沒有 IOReport 的能量模型，但 SMC 直接提供 CPU 核心（PCPC）與內顯（PCPG）功率
    private lazy var smcChipPower = smc?.hasKey("PCPC") ?? false
    private var delta = EnergyDelta()
    private var previousSystem: Double?
    private var previousBacklight: Double?
    private var previousTime: TimeInterval?

    func reset() { delta.reset(); previousTime = nil; previousSystem = nil; previousBacklight = nil }

    func sample() -> ComponentPowerSample {
        let now = ProcessInfo.processInfo.systemUptime
        let energy = report?.sampleEnergy() ?? [:]
        let watts = delta.watts(energy: energy, uptime: now)
        let interval = previousTime.map { now - $0 }
        previousTime = now
        func valid(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value >= 0, value < 500 else { return nil }
            return value
        }
        let system = valid(smc?.read("PSTR"))
        let backlight = valid(smc?.read("PDBR")) ?? valid(smc?.read("PBwo"))
        let windowValid = interval.map { $0 > 0 && $0 <= EnergyDelta.maxWindow } ?? false
        let estimated = windowValid && system != nil && previousSystem != nil
            && (!backlightAvailable || (backlight != nil && previousBacklight != nil))
        let systemAverage = estimated ? (system! + previousSystem!) / 2 : system
        let backlightAverage = estimated && backlightAvailable ? (backlight! + previousBacklight!) / 2 : backlight
        previousSystem = system
        previousBacklight = backlight
        // 在背景執行緒，只讀需要的那一個值；BatteryReader.read 會動到主執行緒共用的快取
        let fallback = system == nil ? BatteryReader.systemLoadWatts() : nil
        let cpu = EnergyCounter.updatedCPUWatts(watts["cpu"]) ?? (smcChipPower ? valid(smc?.read("PCPC")) : nil)
        let gpu = watts["gpu"] ?? (smcChipPower ? valid(smc?.read("PCPG")) : nil)
        return ComponentPowerSample(uptime: now, interval: interval,
            backlightWatts: backlightAverage,
            cpuWatts: cpu, gpuWatts: gpu, aneWatts: watts["ane"],
            systemWatts: systemAverage ?? valid(fallback), systemWindowEstimated: estimated,
            systemPowerSource: system != nil ? "SMC PSTR" : "Battery SystemLoad",
            sampling: interval == nil && !energy.isEmpty,
            aneAvailable: report?.components.contains("ane") ?? false,
            backlightAvailable: backlightAvailable)
    }
}

actor HardwarePowerWorker {
    private var reader: HardwarePowerReader?
    private var generation = -1
    func sample(generation: Int) -> ComponentPowerSample? {
        guard generation >= self.generation else { return nil }
        if generation != self.generation {
            self.generation = generation
            reader = HardwarePowerReader()
        }
        return reader?.sample()
    }
    func stop(generation: Int) {
        guard generation >= self.generation else { return }
        self.generation = generation
        reader = nil
    }
}
