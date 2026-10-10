import Foundation
import Observation

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case iconAndPercent
    case iconOnly
    case percentOnly
    case iconAndTime
    case iconPercentAndTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iconAndPercent: return "圖示 + 百分比"
        case .iconOnly: return "只有圖示"
        case .percentOnly: return "只有百分比"
        case .iconAndTime: return "圖示 + 剩餘時間"
        case .iconPercentAndTime: return "圖示內百分比 + 剩餘時間"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults = UserDefaults.standard
    /// 影響選單列圖示的設定改變時呼叫
    @ObservationIgnored var onChange: (() -> Void)?
    /// 系統監控模組開關改變時呼叫
    @ObservationIgnored var onMonitorsChange: (() -> Void)?
    /// 省電模式切換時呼叫（重設所有取樣間隔）
    @ObservationIgnored var onPowerSavingChange: (() -> Void)?

    /// 省電模式：所有資訊改為每 2 秒取樣一次，電力流向改用靜態圖示、不播放動畫
    var powerSaving: Bool {
        didSet { defaults.set(powerSaving, forKey: Keys.powerSaving); onPowerSavingChange?() }
    }

    /// 電池、系統監控、耗電排行共用的取樣間隔（秒）
    var sampleInterval: TimeInterval { powerSaving ? 2 : 1 }

    /// 介面上顯示的更新頻率
    var updateText: String { powerSaving ? "每 2 秒更新" : "每秒更新" }

    /// 每個系統監控模組是否在選單列顯示（並依取樣間隔更新）
    var monitorCPU: Bool {
        didSet { defaults.set(monitorCPU, forKey: Keys.monitorCPU); onMonitorsChange?() }
    }
    var monitorMemory: Bool {
        didSet { defaults.set(monitorMemory, forKey: Keys.monitorMemory); onMonitorsChange?() }
    }
    var monitorDisk: Bool {
        didSet { defaults.set(monitorDisk, forKey: Keys.monitorDisk); onMonitorsChange?() }
    }
    var monitorNetwork: Bool {
        didSet { defaults.set(monitorNetwork, forKey: Keys.monitorNetwork); onMonitorsChange?() }
    }

    func isMonitorEnabled(_ kind: MonitorKind) -> Bool {
        switch kind {
        case .cpu: return monitorCPU
        case .memory: return monitorMemory
        case .disk: return monitorDisk
        case .network: return monitorNetwork
        }
    }

    var adminCPUSampling: Bool {
        didSet { defaults.set(adminCPUSampling, forKey: "adminCPUSampling"); onChange?() }
    }

    var display: MenuBarDisplay {
        didSet { defaults.set(display.rawValue, forKey: Keys.display); onChange?() }
    }
    var lowAlertEnabled: Bool {
        didSet { defaults.set(lowAlertEnabled, forKey: Keys.lowAlertEnabled) }
    }
    var lowThreshold: Int {
        didSet { defaults.set(lowThreshold, forKey: Keys.lowThreshold); onChange?() }
    }
    var fullAlertEnabled: Bool {
        didSet { defaults.set(fullAlertEnabled, forKey: Keys.fullAlertEnabled) }
    }
    var fullThreshold: Int {
        didSet { defaults.set(fullThreshold, forKey: Keys.fullThreshold) }
    }

    private enum Keys {
        static let display = "menuBarDisplay"
        static let lowAlertEnabled = "lowAlertEnabled"
        static let lowThreshold = "lowThreshold"
        static let fullAlertEnabled = "fullAlertEnabled"
        static let fullThreshold = "fullThreshold"
        static let monitorCPU = "monitorCPU"
        static let monitorMemory = "monitorMemory"
        static let monitorDisk = "monitorDisk"
        static let monitorNetwork = "monitorNetwork"
        static let powerSaving = "powerSaving"
    }

    private init() {
        defaults.register(defaults: [
            Keys.display: MenuBarDisplay.iconAndPercent.rawValue,
            Keys.lowAlertEnabled: true,
            Keys.lowThreshold: 20,
            Keys.fullAlertEnabled: true,
            Keys.fullThreshold: 100,
            Keys.monitorCPU: true,
            Keys.monitorMemory: true,
            Keys.monitorDisk: true,
            Keys.monitorNetwork: true,
            Keys.powerSaving: false,
        ])
        adminCPUSampling = defaults.bool(forKey: "adminCPUSampling")
        display = MenuBarDisplay(rawValue: defaults.string(forKey: Keys.display) ?? "") ?? .iconAndPercent
        lowAlertEnabled = defaults.bool(forKey: Keys.lowAlertEnabled)
        lowThreshold = defaults.integer(forKey: Keys.lowThreshold)
        fullAlertEnabled = defaults.bool(forKey: Keys.fullAlertEnabled)
        fullThreshold = defaults.integer(forKey: Keys.fullThreshold)
        monitorCPU = defaults.bool(forKey: Keys.monitorCPU)
        monitorMemory = defaults.bool(forKey: Keys.monitorMemory)
        monitorDisk = defaults.bool(forKey: Keys.monitorDisk)
        monitorNetwork = defaults.bool(forKey: Keys.monitorNetwork)
        powerSaving = defaults.bool(forKey: Keys.powerSaving)
    }
}
