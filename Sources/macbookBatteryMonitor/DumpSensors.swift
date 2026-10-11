import Foundation

/// 開發用：`--dump-sensors [次數]` 每秒印一份感測器表格，列出各溫度感測器的原始值與處理後的值，方便核對。
/// 只讀取，不寫入任何東西。
enum SensorDump {
    private struct Row {
        let name: String
        let key: String
    }

    // M2 系列的核心溫度鍵（在 M2 Pro 實機上以負載測試確認）
    private static let efficiency = ["Tp1h", "Tp1t", "Tp1p", "Tp1l"]
    private static let performance = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
    private static let gpu = ["Tg0f", "Tg0j"]
    private static let others: [Row] = [
        Row(name: "Airport", key: "TW0P"), Row(name: "NAND", key: "TH0x"),
        Row(name: "Battery 1", key: "TB1T"), Row(name: "Battery 2", key: "TB2T"),
        Row(name: "Airflow left", key: "TaLP"), Row(name: "Airflow right", key: "TaRF"),
    ]

    static func run(count: Int) {
        guard let smc = SMC() else {
            print("無法開啟 AppleSMC")
            return
        }
        let thermal = ThermalReader()
        var held: [String: Double] = [:]   // 保留舊值：讀值 <10 或 >120 就沿用上一次的值

        func line(_ name: String, _ key: String, group: Bool) -> (value: Double?, text: String) {
            guard let raw = smc.read(key) else { return (nil, String(format: "%-24@ %@  —", name as NSString, key as NSString)) }
            let discarded = group && (raw < 10 || raw > 120)
            let heldValue = discarded ? held[key] : raw
            if let heldValue, !discarded { held[key] = heldValue }
            let status = group ? (ThermalMath.isValidDieTemperature(raw) ? "有效" : "休眠假值") : "有效"
            let shown = heldValue.map { String(format: "%6.1f", $0) } ?? "   n/a"
            let text = String(format: "%-24@ %@  原始 %6.1f  保留舊值 %@  %@", name as NSString, key as NSString, raw, shown as NSString, status as NSString)
            return (heldValue, text)
        }

        for i in 0..<max(1, count) {
            let stamp = DateFormatter()
            stamp.dateFormat = "HH:mm:ss"
            print("===== \(stamp.string(from: Date()))（第 \(i + 1) 次）=====")
            var cpuValues: [Double] = []
            var cpuValid: [Double] = []
            for (index, key) in efficiency.enumerated() {
                let r = line("CPU efficiency core \(index + 1)", key, group: true)
                print(r.text)
                if let v = r.value { cpuValues.append(v) }
                if let raw = smc.read(key), ThermalMath.isValidDieTemperature(raw) { cpuValid.append(raw) }
            }
            for (index, key) in performance.enumerated() {
                let r = line("CPU performance core \(index + 1)", key, group: true)
                print(r.text)
                if let v = r.value { cpuValues.append(v) }
                if let raw = smc.read(key), ThermalMath.isValidDieTemperature(raw) { cpuValid.append(raw) }
            }
            var gpuValues: [Double] = []
            var gpuValid: [Double] = []
            for (index, key) in gpu.enumerated() {
                let r = line("GPU \(index + 1)", key, group: true)
                print(r.text)
                if let v = r.value { gpuValues.append(v) }
                if let raw = smc.read(key), ThermalMath.isValidDieTemperature(raw) { gpuValid.append(raw) }
            }
            func avg(_ v: [Double]) -> String { v.isEmpty ? "n/a" : String(format: "%.1f", v.reduce(0, +) / Double(v.count)) }
            func top(_ v: [Double]) -> String { v.max().map { String(format: "%.1f", $0) } ?? "n/a" }
            print("-- 保留舊值（壞值沿用上一次）  Average CPU \(avg(cpuValues))  Hottest CPU \(top(cpuValues))  Average GPU \(avg(gpuValues))")
            print("-- 只算此刻有效的感測器          Average CPU \(avg(cpuValid))  Hottest CPU \(top(cpuValid))  Average GPU \(avg(gpuValid))  （有效 CPU \(cpuValid.count)/12）")
            for row in others { print(line(row.name, row.key, group: false).text) }
            for fan in thermal.fans() {
                print(String(format: "%-24@ %5.0f RPM  %4.0f%%  (最低 %.0f／最高 %.0f)", fan.name as NSString, fan.rpm,
                             fan.fraction * 100, fan.minRPM, fan.maxRPM))
            }
            let panel = thermal.temperatures()
            func stat(_ s: TemperatureSummary.Stat?) -> String {
                s.map { String(format: "平均 %.1f／最高 %.1f", $0.average, $0.maximum) } ?? "—"
            }
            print("-- 面板顯示值（各感測器保留 120 秒） CPU \(stat(panel.cpu))  GPU \(stat(panel.gpu))  SoC \(stat(panel.soc))")
            if i + 1 < count { Thread.sleep(forTimeInterval: 1) }
        }
    }
}
