import AppKit
import Charts
import SwiftUI

/// 系統監控模組的面板。只裝 Command Line Tools 時不能用 @State，畫面只讀取各模組的資料
struct MonitorPanel: View {
    let kind: MonitorKind
    let cpu: CPUMonitor
    let memory: MemoryMonitor
    let disk: DiskMonitor
    let network: NetworkMonitor
    var onSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            switch kind {
            case .cpu: CPUPanel(cpu: cpu)
            case .memory: MemoryPanel(memory: memory)
            case .disk: DiskPanel(disk: disk)
            case .network: NetworkPanel(network: network)
            }
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var updated: Date? {
        switch kind {
        case .cpu: return cpu.updated
        case .memory: return memory.updated
        case .disk: return disk.updated
        case .network: return network.updated
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let updated {
                Text("\(AppSettings.shared.updateText)・\(updated.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(action: onSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("設定")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("結束電池監控")
        }
    }
}

// MARK: - 共用元件

private struct PanelHeader: View {
    let symbol: String
    let title: String
    let value: String
    let detail: String
    var tint: Color = .primary

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var tint: Color? = nil

    init(_ label: String, _ value: String, tint: Color? = nil) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    var body: some View {
        HStack {
            if let tint {
                Circle().fill(tint).frame(width: 7, height: 7)
            }
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

/// 最近 2 分鐘的兩條線；percent 時 y 軸固定 0～100%
private struct MonitorChart: View {
    let points: [MonitorPoint]
    let a: (name: String, color: Color)
    let b: (name: String, color: Color)?
    var percent = false
    /// 上方已經有帶顏色圓點的數值列時不必重複圖例
    var showsLegend = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if showsLegend {
                    legend(a.name, a.color)
                    if let b { legend(b.name, b.color) }
                }
                Spacer()
                Text("最近 2 分鐘")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if points.count < 2 {
                Text("收集中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                chart
                    .frame(height: 70)
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("時間", p.t), y: .value(a.name, p.a), series: .value("線", a.name))
                    .foregroundStyle(a.color.opacity(0.18))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("時間", p.t), y: .value(a.name, p.a), series: .value("線", a.name))
                    .foregroundStyle(a.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            if let b {
                ForEach(points) { p in
                    LineMark(x: .value("時間", p.t), y: .value(b.name, p.b), series: .value("線", b.name))
                        .foregroundStyle(b.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYScale(domain: percent ? 0...1 : 0...max(1, yMax))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(percent ? ByteFormat.percent(v) : ByteFormat.compactRate(v))
                    }
                }
            }
        }
    }

    private var yMax: Double {
        points.map { max($0.a, $0.b) }.max() ?? 1
    }

    private func legend(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// 使用量最高的 App；同一個 App 的子程序已合併
private struct TopList: View {
    let title: String
    let processes: [TopProcess]
    let loaded: Bool
    let valueText: (Double) -> String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                CardTitle(title, systemImage: "list.number")
                if !loaded {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else if processes.isEmpty {
                    Text("目前沒有明顯的使用量")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(processes) { p in
                        HStack(spacing: 8) {
                            icon(for: p)
                                .frame(width: 16, height: 16)
                            Text(p.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(valueText(p.value))
                                .monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func icon(for p: TopProcess) -> some View {
        if let path = p.appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
        } else {
            Image(systemName: "gearshape.fill")
                .resizable()
                .scaledToFit()
                .padding(2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - CPU／GPU

private struct CPUPanel: View {
    let cpu: CPUMonitor

    var body: some View {
        VStack(spacing: 10) {
            PanelHeader(symbol: "cpu", title: "CPU",
                        value: cpu.usage.map { ByteFormat.percent($0.total) } ?? "—",
                        detail: cpu.usage.map { "使用者 \(ByteFormat.percent($0.user))・系統 \(ByteFormat.percent($0.system))" } ?? "計算中…")
            Card {
                MonitorChart(points: cpu.history.points, a: ("CPU", .green), b: ("GPU", .orange), percent: true)
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle("各核心", systemImage: "square.grid.3x3")
                    let e = cpu.layout.efficiency
                    if cpu.cores.count > e, e > 0 {
                        CoreBars(title: "效能核心", cores: Array(cpu.cores[e...]), color: .green)
                        CoreBars(title: "節能核心", cores: Array(cpu.cores[..<e]), color: .mint)
                    } else {
                        CoreBars(title: "核心", cores: cpu.cores, color: .green)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow("GPU 使用率", cpu.gpu.map(ByteFormat.percent) ?? "—")
                    InfoRow("GPU 記憶體", cpu.gpuMemory.map(ByteFormat.memory) ?? "—")
                    InfoRow("平均負載（1／5／15 分）", cpu.load.isEmpty ? "—" : cpu.load.map { String(format: "%.2f", $0) }.joined(separator: "／"))
                }
            }
            TopList(title: "CPU 使用率最高的 App", processes: cpu.topProcesses, loaded: cpu.topLoaded) {
                String(format: "%.1f%%", $0)
            }
        }
    }
}

private struct CoreBars: View {
    let title: String
    let cores: [CPUUsage]
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(cores.enumerated()), id: \.offset) { _, core in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08))
                        RoundedRectangle(cornerRadius: 2).fill(color.gradient)
                            .frame(height: max(2, 30 * core.total))
                    }
                    .frame(width: 14, height: 30)
                    .help(ByteFormat.percent(core.total))
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 記憶體

private struct MemoryPanel: View {
    let memory: MemoryMonitor

    var body: some View {
        VStack(spacing: 10) {
            if let m = memory.usage {
                PanelHeader(symbol: "memorychip", title: "記憶體",
                            value: ByteFormat.percent(m.usedFraction),
                            detail: "已使用 \(ByteFormat.memory(m.used)) / \(ByteFormat.memory(m.total))",
                            tint: tint(m.pressure))
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CompositionBar(segments: segments(m), total: m.total)
                        ForEach(segments(m), id: \.name) { s in
                            InfoRow(s.name, ByteFormat.memory(s.bytes), tint: s.color)
                        }
                    }
                }
                Card {
                    MonitorChart(points: memory.history.points, a: ("已使用", .blue), b: nil, percent: true)
                }
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        InfoRow("記憶體壓力", m.pressure.title)
                        InfoRow("Swap 已使用", m.swapTotal > 0 ? "\(ByteFormat.memory(m.swapUsed)) / \(ByteFormat.memory(m.swapTotal))" : "未使用")
                    }
                }
            } else {
                PanelHeader(symbol: "memorychip", title: "記憶體", value: "—", detail: "讀取中…")
            }
            TopList(title: "使用記憶體最多的 App", processes: memory.topProcesses, loaded: memory.topLoaded) {
                ByteFormat.memory(UInt64($0))
            }
        }
    }

    private struct Segment {
        let name: String
        let bytes: UInt64
        let color: Color
    }

    private func segments(_ m: MemoryUsage) -> [Segment] {
        [
            Segment(name: "App 記憶體", bytes: m.app, color: .blue),
            Segment(name: "系統保留", bytes: m.wired, color: .orange),
            Segment(name: "已壓縮", bytes: m.compressed, color: .purple),
            Segment(name: "檔案快取", bytes: m.cached, color: .gray),
            Segment(name: "可用", bytes: m.free, color: Color.primary.opacity(0.12)),
        ]
    }

    private func tint(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: return .primary
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private struct CompositionBar: View {
        let segments: [Segment]
        let total: UInt64

        var body: some View {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(segments, id: \.name) { s in
                        Rectangle()
                            .fill(s.color)
                            .frame(width: total > 0 ? max(0, geo.size.width * CGFloat(Double(s.bytes) / Double(total)) - 1) : 0)
                    }
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

// MARK: - 磁碟

private struct DiskPanel: View {
    let disk: DiskMonitor

    var body: some View {
        VStack(spacing: 10) {
            let v = disk.volume
            let fraction = v.map { $0.total > 0 ? Double($0.used) / Double($0.total) : 0 } ?? 0
            PanelHeader(symbol: "internaldrive", title: v?.name ?? "磁碟",
                        value: v == nil ? "—" : ByteFormat.percent(fraction),
                        detail: v.map { "可用 \(ByteFormat.size($0.available))・共 \(ByteFormat.size($0.total))" } ?? "讀取中…")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: fraction)
                        .tint(fraction > 0.9 ? .red : fraction > 0.8 ? .orange : .blue)
                    InfoRow("已使用", v.map { ByteFormat.size($0.used) } ?? "—")
                    InfoRow("可用", v.map { ByteFormat.size($0.available) } ?? "—")
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    InfoRow("讀取", ByteFormat.rate(disk.readRate), tint: .green)
                    InfoRow("寫入", ByteFormat.rate(disk.writeRate), tint: .orange)
                    MonitorChart(points: disk.history.points, a: ("讀取", .green), b: ("寫入", .orange), showsLegend: false)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle("開機以來", systemImage: "clock.arrow.circlepath")
                    InfoRow("累計讀取", ByteFormat.size(disk.totalRead))
                    InfoRow("累計寫入", ByteFormat.size(disk.totalWritten))
                }
            }
        }
    }
}

// MARK: - 網路

private struct NetworkPanel: View {
    let network: NetworkMonitor

    var body: some View {
        VStack(spacing: 10) {
            PanelHeader(symbol: "network", title: network.kind.map { "\($0)（\(network.interface ?? "")）" } ?? "網路",
                        value: "↓ " + ByteFormat.compactRate(network.downloadRate),
                        detail: network.interface == nil ? "未連線" : "IP \(network.address ?? "—")")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    InfoRow("下載", ByteFormat.rate(network.downloadRate), tint: .green)
                    InfoRow("上傳", ByteFormat.rate(network.uploadRate), tint: .orange)
                    MonitorChart(points: network.history.points, a: ("下載", .green), b: ("上傳", .orange), showsLegend: false)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle("開機以來（目前的網路介面）", systemImage: "clock.arrow.circlepath")
                    InfoRow("累計下載", ByteFormat.size(network.totalReceived))
                    InfoRow("累計上傳", ByteFormat.size(network.totalSent))
                }
            }
        }
    }
}
