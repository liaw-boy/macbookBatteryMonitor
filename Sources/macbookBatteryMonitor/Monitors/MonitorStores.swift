import Foundation
import Observation

/// 各模組由 ModuleCoordinator 依更新頻率呼叫 sample()；面板打開時另外接收 top 的程序排行

@MainActor
@Observable
final class CPUMonitor {
    private(set) var usage: CPUUsage?
    private(set) var cores: [CPUUsage] = []
    private(set) var gpu: Double?
    private(set) var gpuMemory: UInt64?
    private(set) var load: [Double] = []
    /// a：CPU 總使用率、b：GPU 使用率（0～1）
    private(set) var history = MonitorHistory()
    private(set) var topProcesses: [TopProcess] = []
    private(set) var topLoaded = false
    private(set) var updated: Date?
    let layout = CPUReader.coreLayout

    @ObservationIgnored private var lastTicks: [CPUTicks]?

    func sample(at now: Date = Date()) {
        if let ticks = CPUReader.ticks() {
            if let last = lastTicks, let result = CPUMath.usages(from: last, to: ticks) {
                usage = result.total
                cores = result.cores
            }
            lastTicks = ticks
        }
        let gpuReading = GPUReader.read()
        gpu = gpuReading.utilization
        gpuMemory = gpuReading.memory
        load = CPUReader.loadAverage()
        if let usage { history.append(usage.total, gpu ?? 0, at: now) }
        updated = now
    }

    func receiveTop(_ text: String) {
        let list = ProcessOwner.group(TopParse.rows(text), value: { Double($0) }, limit: 5)
        // top 第一段沒有差值，CPU 欄全為 0；拿到有效資料才更新
        guard !list.isEmpty else { return }
        topProcesses = list
        topLoaded = true
    }

    func clearTop() {
        topProcesses = []
        topLoaded = false
    }
}

@MainActor
@Observable
final class MemoryMonitor {
    private(set) var usage: MemoryUsage?
    /// a：已使用比例（0～1）
    private(set) var history = MonitorHistory()
    private(set) var topProcesses: [TopProcess] = []
    private(set) var topLoaded = false
    private(set) var updated: Date?

    func sample(at now: Date = Date()) {
        if let reading = MemoryReader.read() {
            usage = reading
            history.append(reading.usedFraction, at: now)
        }
        updated = now
    }

    func receiveTop(_ text: String) {
        topProcesses = ProcessOwner.group(TopParse.rows(text), value: TopParse.memoryBytes, limit: 5)
        topLoaded = true
    }

    func clearTop() {
        topProcesses = []
        topLoaded = false
    }
}

@MainActor
@Observable
final class DiskMonitor {
    private(set) var volume: DiskReader.Volume?
    private(set) var readRate: Double = 0
    private(set) var writeRate: Double = 0
    /// 自開機以來的累計讀寫
    private(set) var totalRead: UInt64 = 0
    private(set) var totalWritten: UInt64 = 0
    /// a：讀取、b：寫入（位元組／秒）
    private(set) var history = MonitorHistory()
    private(set) var updated: Date?

    @ObservationIgnored private var last: (read: UInt64, written: UInt64, date: Date)?

    func sample(at now: Date = Date()) {
        if let reading = DiskReader.startupVolume() { volume = reading }
        if let io = DiskReader.ioBytes() {
            if let last {
                let interval = now.timeIntervalSince(last.date)
                readRate = RateMath.perSecond(old: last.read, new: io.read, interval: interval)
                writeRate = RateMath.perSecond(old: last.written, new: io.written, interval: interval)
                history.append(readRate, writeRate, at: now)
            }
            last = (io.read, io.written, now)
            totalRead = io.read
            totalWritten = io.written
        }
        updated = now
    }
}

@MainActor
@Observable
final class NetworkMonitor {
    private(set) var interface: String?
    /// Wi-Fi、乙太網路等
    private(set) var kind: String?
    private(set) var address: String?
    private(set) var downloadRate: Double = 0
    private(set) var uploadRate: Double = 0
    /// 目前介面自開機以來的累計收發
    private(set) var totalReceived: UInt64 = 0
    private(set) var totalSent: UInt64 = 0
    /// a：下載、b：上傳（位元組／秒）
    private(set) var history = MonitorHistory()
    private(set) var updated: Date?

    @ObservationIgnored private var last: (interface: String, received: UInt64, sent: UInt64, date: Date)?

    func sample(at now: Date = Date()) {
        let primary = NetworkReader.primaryInterface()
        if primary != interface {
            interface = primary
            // 介面類型查詢較慢，只在切換網路時查
            kind = primary.map(NetworkReader.kind(of:))
            last = nil
        }
        address = primary.flatMap(NetworkReader.ipv4Address(of:))

        guard let primary, let counter = NetworkReader.counters(for: primary) else {
            downloadRate = 0
            uploadRate = 0
            history.append(0, 0, at: now)
            updated = now
            return
        }
        if let last, last.interface == primary {
            let interval = now.timeIntervalSince(last.date)
            downloadRate = RateMath.perSecond(old: last.received, new: counter.received, interval: interval)
            uploadRate = RateMath.perSecond(old: last.sent, new: counter.sent, interval: interval)
            history.append(downloadRate, uploadRate, at: now)
        }
        last = (primary, counter.received, counter.sent, now)
        totalReceived = counter.received
        totalSent = counter.sent
        updated = now
    }
}

// MARK: - 截圖用的示範數據（README、版本說明），不含任何使用者的真實資料

private func previewHistory(count: Int = MonitorHistory.capacity, now: Date, _ value: (Double) -> (Double, Double)) -> MonitorHistory {
    var history = MonitorHistory()
    for i in 0..<count {
        let v = value(Double(i))
        history.append(v.0, v.1, at: now.addingTimeInterval(Double(i - count)))
    }
    return history
}

private func previewApps(_ values: [Double]) -> [TopProcess] {
    let apps = [("Safari", "/Applications/Safari.app"), ("照片", "/System/Applications/Photos.app"),
                ("音樂", "/System/Applications/Music.app"), ("郵件", "/System/Applications/Mail.app"),
                ("Finder", "/System/Library/CoreServices/Finder.app")]
    return zip(apps, values).map { TopProcess(id: $0.0.1, name: $0.0.0, value: $0.1, appPath: $0.0.1) }
}

extension CPUMonitor {
    func loadPreview(now: Date = Date()) {
        usage = CPUUsage(user: 0.18, system: 0.09)
        let e = max(layout.efficiency, 4), p = max(layout.performance, 4)
        cores = (0..<e).map { CPUUsage(user: 0.30 - Double($0) * 0.04, system: 0.10) }
            + (0..<p).map { CPUUsage(user: 0.20 - Double($0) * 0.04, system: 0.05) }
        gpu = 0.12
        gpuMemory = 512 * 1024 * 1024
        load = [2.35, 2.10, 1.98]
        history = previewHistory(now: now) { (0.25 + 0.08 * sin($0 / 7) + 0.04 * sin($0 / 2.3), 0.10 + 0.05 * sin($0 / 11)) }
        topProcesses = previewApps([34.5, 12.2, 8.1, 3.4, 1.6])
        topLoaded = true
        updated = now
    }
}

extension MemoryMonitor {
    func loadPreview(now: Date = Date()) {
        let gib: UInt64 = 1024 * 1024 * 1024
        usage = MemoryUsage(total: 16 * gib, app: 6 * gib + gib / 4, wired: 2 * gib + gib / 10, compressed: gib + gib / 2,
                            cached: 3 * gib + gib / 2, swapUsed: 0, swapTotal: 0, pressure: .normal)
        history = previewHistory(now: now) { (0.61 + 0.015 * sin($0 / 13), 0) }
        topProcesses = previewApps([1.8, 0.82, 0.41, 0.38, 0.16].map { $0 * Double(gib) })
        topLoaded = true
        updated = now
    }
}

extension DiskMonitor {
    func loadPreview(now: Date = Date()) {
        volume = DiskReader.Volume(name: "Macintosh HD", total: 494_384_795_648, available: 312_000_000_000)
        readRate = 2_400_000
        writeRate = 900_000
        totalRead = 85_000_000_000
        totalWritten = 41_000_000_000
        history = previewHistory(now: now) { i in
            (max(0, 1_500_000 + 1_200_000 * sin(i / 5)), max(0, 600_000 + 500_000 * sin(i / 8 + 1)))
        }
        updated = now
    }
}

extension NetworkMonitor {
    func loadPreview(now: Date = Date()) {
        interface = "en0"
        kind = "Wi-Fi"
        address = "192.168.1.23"
        downloadRate = 2_800_000
        uploadRate = 340_000
        totalReceived = 12_400_000_000
        totalSent = 1_900_000_000
        history = previewHistory(now: now) { i in
            (max(0, 2_000_000 + 1_500_000 * sin(i / 6)), max(0, 300_000 + 150_000 * sin(i / 4 + 2)))
        }
        updated = now
    }
}
