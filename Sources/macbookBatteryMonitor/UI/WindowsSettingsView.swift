import SwiftUI

/// 設定 →「視窗與 Dock」：視窗切換以外、和視窗或 Dock 有關的擴充功能
struct WindowsSettingsView: View {
    let settings: AppSettings
    let ui: PanelState

    var body: some View {
        if settings.isInstalled(.finderKeys) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle("Finder 快捷鍵", systemImage: "folder")
                    Text("⌘X 剪下、⌘V 搬移檔案，F2 重新命名。剪下後又複製了別的東西，⌘V 就照常貼上，不會誤搬檔案。改檔名或在搜尋框打字時不作用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    status(running: ui.finderKeysRunning)
                }
            }
        }
        if settings.isInstalled(.windowSnap) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle("視窗吸附", systemImage: "rectangle.split.2x1")
                    Text("拖到左右邊緣排成半邊、上緣填滿、四個角排成四分之一。先顯示預覽，放開才排版，拖離邊緣就取消。系統設定已開「拖移視窗到螢幕邊緣以並排」時交給系統處理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    status(running: ui.windowSnapRunning)
                }
            }
        }
        if settings.isInstalled(.greenButton) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle("綠色按鈕填滿", systemImage: "arrow.up.left.and.arrow.down.right")
                    Text("點綠色按鈕填滿所在螢幕（不進全螢幕，選單列與 Dock 還在），再點一次還原。按住 Option 點照系統原本的行為。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    status(running: ui.greenButtonRunning)
                }
            }
        }
        if settings.isInstalled(.dockClick) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle("點 Dock 圖示收起", systemImage: "dock.arrow.down.rectangle")
                    Picker("點最前面 App 的圖示時", selection: Binding(get: { settings.dockClickMode }, set: { settings.dockClickMode = $0 })) {
                        Text("視窗縮到 Dock").tag(DockClick.Mode.minimize)
                        Text("隱藏 App").tag(DockClick.Mode.hide)
                    }
                    Text("只在點最前面、而且有開著視窗的 App 時作用，再點一次叫回來。點別的 App、拖曳、按右鍵都照常。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    status(running: ui.dockClickRunning)
                }
            }
        }
        if settings.isInstalled(.lastWindowQuit) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle("關掉最後視窗就結束", systemImage: "xmark.app")
                    Text("App 的最後一個視窗關掉就結束它（縮到 Dock 的也算還開著）。Finder、隱藏中的 App 和下面列出的 App 不會結束，例如要在背景播音樂的 App。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    AppExceptionList(ids: Binding(get: { settings.lastWindowQuitExcluded }, set: { settings.lastWindowQuitExcluded = $0 }),
                                     limit: SwitcherSettings.maxExcludedApps)
                    status(running: ui.lastWindowQuitRunning)
                }
            }
        }
    }

    @ViewBuilder private func status(running: Bool) -> some View {
        if running {
            Label("運作中", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else if !ui.scrollTrusted {
            Text("需要允許「輔助使用」：系統設定 → 隱私權與安全性 → 輔助使用，打開「\(AppEdition.appName)」。")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("打開輔助使用設定") { ScrollDirection.openAccessibilitySettings() }
        }
    }
}
