import Foundation

/// 電力流向細項（系統細項、晶片細項）可以自己決定要不要顯示的項目
enum FlowItem: String, CaseIterable, Identifiable {
    case backlight, chip, other
    case cpu, gpu, ane

    var id: String { rawValue }

    var title: String {
        switch self {
        case .backlight: return "螢幕背光"
        case .chip: return "晶片運算"
        case .other: return "其他（估算）"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .ane: return "ANE"
        }
    }

    /// 屬於「晶片運算」展開後的那一層
    var isChipDetail: Bool { self == .cpu || self == .gpu || self == .ane }

    static let systemLevel: [FlowItem] = [.backlight, .chip, .other]
    static let chipLevel: [FlowItem] = [.cpu, .gpu, .ane]
}

/// 「詳細資訊」分頁可以自己決定要不要顯示的欄位，順序即畫面上的順序（每列兩欄）
enum DetailField: String, CaseIterable, Identifiable {
    case voltage, current, batteryPower, systemPower
    case systemEstimate, temperature, health, computedHealth
    case cycles, condition, remaining, fullCharge
    case design, lowPower, adapter, chargeLimit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .voltage: return "電壓"
        case .current: return "電流"
        case .batteryPower: return "電池功率"
        case .systemPower: return "系統耗電"
        case .systemEstimate: return "系統預估"
        case .temperature: return "溫度"
        case .health: return "健康度"
        case .computedHealth: return "容量推算"
        case .cycles: return "循環次數"
        case .condition: return "電池狀況"
        case .remaining: return "剩餘容量"
        case .fullCharge: return "滿充容量"
        case .design: return "設計容量"
        case .lowPower: return "低耗電模式"
        case .adapter: return "變壓器"
        case .chargeLimit: return "充電上限"
        }
    }
}
