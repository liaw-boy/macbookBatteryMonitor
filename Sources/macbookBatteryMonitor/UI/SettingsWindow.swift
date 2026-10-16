import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, display, monitoring, charging

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "一般"
        case .display: return "電池顯示項目"
        case .monitoring: return "監控與省電"
        case .charging: return "智慧充電"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .display: return "list.bullet.rectangle"
        case .monitoring: return "gauge.with.dots.needle.33percent"
        case .charging: return "checkmark.shield"
        }
    }
}

/// 設定視窗的介面狀態（只裝 Command Line Tools 時不能用 @State，所以放在這裡）
@MainActor
@Observable
final class SettingsWindowState {
    var section: SettingsSection = .general
}

/// 獨立的設定視窗：左側分類、右側內容。內容沿用 SettingsView 的卡片
struct SettingsWindowView: View {
    let store: BatteryStore
    let settings: AppSettings
    let ui: PanelState
    let state: SettingsWindowState

    private var hasBattery: Bool { store.snapshot != nil }

    private var sections: [SettingsSection] {
        SettingsSection.allCases.filter { $0 != .charging || hasBattery }
    }

    private var content: SettingsView {
        SettingsView(settings: settings, ui: ui, adminCPU: store.adminCPU, updater: store.updater,
                     chargeLimit: store.chargeLimit, hasBattery: hasBattery,
                     hidesDisplayItemsButton: true)
    }

    var body: some View {
        NavigationSplitView {
            List(sections, selection: Binding(get: { state.section }, set: { state.section = $0 ?? .general })) { section in
                Label(section.title, systemImage: section.systemImage)
                    .padding(.vertical, 6)
                    .tag(section)
            }
            .safeAreaInset(edge: .bottom, alignment: .leading) {
                HStack {
                    Text("\(AppEdition.appName) \(store.updater.currentVersion)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Image(systemName: "power")
                    }
                    .buttonStyle(.borderless)
                    .help("結束\(AppEdition.appName)")
                    .accessibilityLabel("結束\(AppEdition.appName)")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(state.section.title).font(.title2.weight(.semibold))
                    detail
                }
                .padding(20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 680, minHeight: 440)
        .onAppear { content.refreshState() }
    }

    @ViewBuilder private var detail: some View {
        let c = content
        switch state.section {
        case .general:
            c.appIconCard
            c.notificationsCard
            c.launchCard
            UpdateCard(updater: store.updater, settings: settings, notificationsBlocked: ui.notificationsBlocked, ui: ui)
        case .display:
            c.menuBarCard
            DisplayItemsView(settings: settings, ui: ui, limitSlider: store.chargeLimit.supported, embedded: true)
        case .monitoring:
            c.powerSavingCard
            c.monitorsCard
            c.cpuCard
        case .charging:
            ChargingPlanView(store: store, settings: settings, ui: ui, embedded: true)
        }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let state = SettingsWindowState()

    func show(store: BatteryStore, settings: AppSettings, ui: PanelState,
              section: SettingsSection? = nil) {
        if let section { state.section = section }
        // 選單列 App 沒有 Dock 圖示，切去別的 App 再回來時視窗會被蓋在後面找不到；
        // 視窗開著時暫時當一般 App，關窗後再切回去
        NSApp.setActivationPolicy(.regular)
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let hosting = NSHostingController(rootView: SettingsWindowView(
            store: store, settings: settings, ui: ui, state: state))
        let window = NSWindow(contentViewController: hosting)
        window.title = "\(AppEdition.appName) 設定"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 560))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
