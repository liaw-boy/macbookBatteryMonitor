import AppKit
import SwiftUI

/// App 圖示的背景色。薄荷綠是內建圖示，其他顏色的圖放在 Contents/Resources/icon-<顏色>.png
enum AppIconColor: String, CaseIterable, Identifiable {
    case mint, peach, night, sky

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mint: return "薄荷綠"
        case .peach: return "暖杏色"
        case .night: return "深夜藍"
        case .sky: return "天空藍"
        }
    }

    /// 設定頁色塊用的上下漸層（與 Scripts/make-icon.swift 相同）
    var swatch: [Color] {
        func color(_ hex: UInt32) -> Color {
            Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        }
        switch self {
        case .mint: return [color(0xD3F5E6), color(0x6CCBAA)]
        case .peach: return [color(0xFFE9D2), color(0xF3B486)]
        case .night: return [color(0x34467A), color(0x141C38)]
        case .sky: return [color(0x9CCBF5), color(0x5B93D3)]
        }
    }
}

/// 更換「應用程式」資料夾、Finder、Launchpad 看到的 App 圖示（等同「取得資訊」貼上自訂圖示）。
/// 通知與登入項目用的是內建圖示，不受影響。用新版覆蓋 App 後自訂圖示會消失，啟動時再套回去。
@MainActor
enum AppIconChanger {
    /// 只有正式打包的 App 才動手；開發用的執行檔沒有 .app 可以換
    private static var bundlePath: String? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app", Bundle.main.bundleIdentifier == "com.kuan.batterymonitor" else { return nil }
        return url.path
    }

    /// Finder 自訂圖示會在 App 最上層建立這個檔案
    private static var hasCustomIcon: Bool {
        bundlePath.map { FileManager.default.fileExists(atPath: $0 + "/Icon\r") } ?? false
    }

    /// 套用圖示；失敗時回傳原因（例如 App 所在位置沒有寫入權限）
    @discardableResult
    static func apply(_ color: AppIconColor) -> String? {
        guard let path = bundlePath else { return nil }
        let image: NSImage?
        if color == .mint {
            // 內建圖示就是薄荷綠：拿掉自訂圖示即可
            guard hasCustomIcon else { return nil }
            image = nil
        } else {
            guard let url = Bundle.main.url(forResource: "icon-\(color.rawValue)", withExtension: "png"),
                  let loaded = NSImage(contentsOf: url) else { return "找不到這個顏色的圖示檔" }
            image = loaded
        }
        guard NSWorkspace.shared.setIcon(image, forFile: path, options: []) else {
            return "無法更換圖示：App 所在位置沒有寫入權限"
        }
        NSWorkspace.shared.noteFileSystemChanged(path)
        return nil
    }

    /// 啟動時讓圖示與設定一致：選了其他顏色、但 App 剛被新版覆蓋（自訂圖示不見了）就重新套用；
    /// 設定是內建的薄荷綠卻留著自訂圖示就拿掉。只動這個 App 自己的圖示
    static func restoreIfNeeded(_ color: AppIconColor) {
        guard bundlePath != nil, (color == .mint) == hasCustomIcon else { return }
        apply(color)
    }
}
