import Foundation
import Observation

/// 各模組每秒由 ModuleCoordinator 呼叫 sample()；面板打開時另外接收 top 的程序排行

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
