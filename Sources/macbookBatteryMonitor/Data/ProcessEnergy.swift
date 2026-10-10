import Darwin
import Foundation

struct EnergyProcess: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// top 的 POWER 指標（相對耗電量，不是瓦數）
    var power: Double
    var appPath: String?
}

enum ProcessEnergy {
    private static let arguments = ["-l", "2", "-s", "1", "-o", "power", "-stats", "pid,command,power", "-n", "20"]

    static func sampleSync(limit: Int = 5) -> [EnergyProcess] {
        parse(Shell.runSync("/usr/bin/top", arguments), limit: limit)
    }

    static func sample(limit: Int = 5) async -> [EnergyProcess] {
        parse(await Shell.run("/usr/bin/top", arguments), limit: limit)
    }

    /// top 會印兩次取樣，第一次的 POWER 都是 0，只用最後一段。
    /// 同一個 App 的 helper 程序（例如瀏覽器分頁）會合併到 App 名下。
    static func parse(_ output: String?, limit: Int) -> [EnergyProcess] {
        guard let output else { return [] }
        let lines = output.components(separatedBy: "\n")
        guard let header = lines.lastIndex(where: { $0.hasPrefix("PID") }) else { return [] }

        var groups: [String: EnergyProcess] = [:]
        for line in lines[(header + 1)...] {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int32(parts[0]), let power = Double(parts[parts.count - 1]), power > 0 else { continue }
            let command = parts[1..<(parts.count - 1)].joined(separator: " ")
            if command == "top" { continue }

            let app = appBundle(for: pid)
            let key = app ?? "pid:\(pid)"
            let name = app.map { FileManager.default.displayName(atPath: $0) } ?? processName(pid) ?? command
            groups[key, default: EnergyProcess(id: key, name: name, power: 0, appPath: app)].power += power
        }
        return Array(groups.values.sorted { $0.power > $1.power }.prefix(limit))
    }

    /// 取最外層的 .app，讓 helper 歸到主程式
    private static func appBundle(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    private static func processName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}

/// 面板停在耗電排行時持續跑一個 top，每秒（省電模式每 2 秒）輸出一次。
/// 比每次重新啟動 top 省資源（每次啟動要等兩次取樣，約 1 秒），也才能真的每秒更新。
final class ProcessEnergyStream {
    private static let marker = Data("Processes:".utf8)
    /// top 的取樣間隔（秒）
    let interval: Int
    private var process: Process?
    private var buffer = Data()
    private let onUpdate: ([EnergyProcess]) -> Void

    init(interval: Int = 1, onUpdate: @escaping ([EnergyProcess]) -> Void) {
        self.interval = max(1, interval)
        self.onUpdate = onUpdate
    }

    func start() {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "0", "-s", "\(interval)", "-o", "power", "-stats", "pid,command,power", "-n", "20"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // top 結束了（被強制結束或閃退）：不停止監聽的話會不停收到空資料，讓 CPU 跑滿
                handle.readabilityHandler = nil
                DispatchQueue.main.async { if let self, self.process === process { self.stop() } }
                return
            }
            DispatchQueue.main.async { if let self, self.process === process { self.append(data) } }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    func stop() {
        guard let process else { return }
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        self.process = nil
        buffer = Data()
    }

    /// 每段取樣以「Processes:」開頭；看到下一段的開頭時，上一段就完整了。
    /// 第一段的 POWER 全是 0（還沒有差值），解析結果為空時保留上一次的排行。
    private func append(_ data: Data) {
        guard process != nil else { return }
        buffer.append(data)
        var markers: [Data.Index] = []
        var from = buffer.startIndex
        while let range = buffer.range(of: Self.marker, in: from..<buffer.endIndex) {
            markers.append(range.lowerBound)
            from = range.upperBound
        }
        guard markers.count >= 2 else { return }
        let complete = buffer[markers[markers.count - 2]..<markers[markers.count - 1]]
        buffer = Data(buffer[markers[markers.count - 1]...])
        let result = ProcessEnergy.parse(String(decoding: complete, as: UTF8.self), limit: 5)
        if !result.isEmpty { onUpdate(result) }
    }
}
