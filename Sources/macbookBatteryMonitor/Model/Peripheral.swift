import Foundation

/// 周邊設備的電量（藍牙鍵盤、滑鼠、觸控板、耳機等）
struct PeripheralBattery: Identifiable, Equatable {
    enum Kind: String { case keyboard, mouse, trackpad, headphones, gameController, other }

    /// 藍牙位址（小寫、冒號分隔）；沒有位址時用序號或名稱
    var id: String
    var name: String
    var kind: Kind
    /// 單一電池的電量（鍵盤、滑鼠，或耳機的主電池）
    var level: Int?
    /// 左右耳與充電盒（AirPods 等）
    var left: Int?
    var right: Int?
    var caseLevel: Int?

    /// 通知與顯示用的代表電量：耳機取左右耳較低者（不含充電盒）
    var lowest: Int? { [left, right].compactMap { $0 }.min() ?? level }

    var symbol: String {
        switch kind {
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .gameController: return "gamecontroller"
        case .headphones:
            if name.localizedCaseInsensitiveContains("AirPods Max") { return "airpodsmax" }
            if name.localizedCaseInsensitiveContains("AirPods Pro") { return "airpodspro" }
            if name.localizedCaseInsensitiveContains("AirPods") { return "airpods" }
            return "headphones"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }

    /// 「左 80%・右 76%・盒 45%」；只有單一電池時為 nil
    var detailText: String? {
        let parts = [left.map { "左 \($0)%" }, right.map { "右 \($0)%" }, caseLevel.map { "盒 \($0)%" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }
}

enum PeripheralParse {
    /// 藍牙位址統一成小寫、冒號分隔（IORegistry 用 -，system_profiler 用 :）
    static func normalizedAddress(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: "-", with: ":")
    }

    static func kind(name: String, minorType: String? = nil) -> PeripheralBattery.Kind {
        let text = ((minorType ?? "") + " " + name).lowercased()
        if text.contains("keyboard") { return .keyboard }
        if text.contains("trackpad") { return .trackpad }
        if text.contains("mouse") { return .mouse }
        if text.contains("headphone") || text.contains("headset") || text.contains("airpods") || text.contains("beats") { return .headphones }
        if text.contains("gamepad") || text.contains("controller") || text.contains("joystick") { return .gameController }
        return .other
    }

    /// "80%" → 80
    static func percent(_ value: Any?) -> Int? {
        if let number = value as? Int { return (0...100).contains(number) ? number : nil }
        guard let text = value as? String,
              let number = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { return nil }
        return (0...100).contains(number) ? number : nil
    }

    /// `system_profiler SPBluetoothDataType -json` 中連線中、有回報電量的設備
    static func bluetooth(json: Data) -> [PeripheralBattery] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var result: [PeripheralBattery] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let device = PeripheralBattery(
                        id: (info["device_address"] as? String).map(normalizedAddress) ?? name,
                        name: name,
                        kind: kind(name: name, minorType: info["device_minorType"] as? String),
                        level: percent(info["device_batteryLevelMain"]) ?? percent(info["device_batteryLevel"]),
                        left: percent(info["device_batteryLevelLeft"]),
                        right: percent(info["device_batteryLevelRight"]),
                        caseLevel: percent(info["device_batteryLevelCase"]))
                    if device.lowest != nil || device.caseLevel != nil { result.append(device) }
                }
            }
        }
        return result
    }

    /// IORegistry 中有 BatteryPercent 的 HID 服務；同一個設備可能有好幾個服務，依 id 合併
    static func hid(_ services: [[String: Any]]) -> [PeripheralBattery] {
        var result: [PeripheralBattery] = []
        for service in services {
            guard let level = percent(service["BatteryPercent"]) else { continue }
            let name = service["Product"] as? String ?? "藍牙設備"
            let id = (service["DeviceAddress"] as? String).map(normalizedAddress)
                ?? (service["SerialNumber"] as? String) ?? name
            guard !result.contains(where: { $0.id == id }) else { continue }
            result.append(PeripheralBattery(id: id, name: name, kind: kind(name: name), level: level))
        }
        return result
    }

    /// 同一個設備兩邊都有時合併：名稱與左右耳用 system_profiler 的（使用者取的藍牙名稱），缺的電量用 HID 補
    static func merge(hid: [PeripheralBattery], bluetooth: [PeripheralBattery]) -> [PeripheralBattery] {
        var merged = bluetooth
        for device in hid {
            if let index = merged.firstIndex(where: { $0.id == device.id }) {
                if merged[index].lowest == nil { merged[index].level = device.level }
                if merged[index].kind == .other { merged[index].kind = device.kind }
            } else {
                merged.append(device)
            }
        }
        return merged.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// 每個設備降到自己的門檻只通知一次；電量回到門檻以上（充過電）才會再通知
struct PeripheralAlerts {
    private(set) var fired: Set<String> = []

    /// 回傳這次要通知的設備；threshold 為 0 表示這個設備不通知
    mutating func evaluate(_ devices: [PeripheralBattery], threshold: (String) -> Int) -> [PeripheralBattery] {
        var due: [PeripheralBattery] = []
        for device in devices {
            guard let level = device.lowest else { continue }
            let limit = threshold(device.id)
            if limit > 0, level <= limit {
                if fired.insert(device.id).inserted { due.append(device) }
            } else if limit == 0 || level > limit + 2 {
                fired.remove(device.id)
            }
        }
        return due
    }
}
