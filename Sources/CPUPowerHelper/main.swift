import Foundation
import CPUPowerShared
import Darwin

/// 所有子程序與租約狀態都只在同一個 queue 存取。
final class CPUSampler {
    let queue = DispatchQueue(label: "com.kuan.batterymonitor.cpu.sampler")
    private var leases = CPUSamplingLeases()
    private var timer: DispatchSourceTimer?
    private var process: Process?
    private var pipe: Pipe?
    private var parser = CPUPowerStream()
    private var reading: CPUPowerReading?
    private var error: String?
    private var disabled = false
    private var stopping = false
    private var token = UUID()

    func sample(client: UUID, active: Bool, reply: @escaping (Data) -> Void) {
        queue.async {
            let now = ProcessInfo.processInfo.systemUptime
            self.leases.set(client, active: active && !self.disabled, at: now)
            self.reconcile()
            let value = active && !self.disabled ? self.reading : nil
            let payload = CPUHelperReply(reading: value, error: self.disabled ? "服務已停用" : self.error)
            reply((try? JSONEncoder().encode(payload)) ?? Data())
        }
    }

    func disconnect(_ client: UUID) {
        queue.async { self.leases.remove(client); self.reconcile() }
    }

    private func reconcile() {
        let active = !disabled && leases.isActive(at: ProcessInfo.processInfo.systemUptime)
        if active {
            if timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
                timer.setEventHandler { [weak self] in self?.reconcile() }
                self.timer = timer
                timer.resume()
            }
            if process == nil && error == nil { start() }
        } else {
            timer?.cancel(); timer = nil
            reading = nil
            error = nil
            if let process, process.isRunning, !stopping {
                stopping = true
                process.terminate()
            }
        }
    }

    private func start() {
        let task = Process(), stream = Pipe(), generation = UUID()
        token = generation
        stopping = false
        parser = CPUPowerStream()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        task.arguments = ["--samplers", "cpu_power", "-i", "1000", "-b", "1"]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = stream
        task.standardError = FileHandle.nullDevice
        stream.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { [weak self] in
                guard let self, self.token == generation, !self.stopping else { return }
                if let watts = self.parser.append(String(decoding: data, as: UTF8.self)) {
                    self.reading = CPUPowerReading(watts: watts, uptime: ProcessInfo.processInfo.systemUptime)
                }
            }
        }
        task.terminationHandler = { [weak self] task in
            self?.queue.async { [weak self] in
                guard let self, self.token == generation else { return }
                self.pipe?.fileHandleForReading.readabilityHandler = nil
                try? self.pipe?.fileHandleForReading.close()
                self.pipe = nil
                self.process = nil
                self.reading = nil
                if !self.stopping { self.error = "系統 CPU 取樣意外停止，請重新啟用功能。" }
                self.stopping = false
                self.reconcile()
            }
        }
        process = task; pipe = stream
        do { try task.run() }
        catch {
            stream.fileHandleForReading.readabilityHandler = nil
            process = nil; pipe = nil
            self.error = "無法啟動系統 CPU 取樣。"
        }
    }

    func uninstall(reply: @escaping (String?) -> Void) {
        queue.async {
            self.disabled = true
            self.reconcile()
            do {
                // 固定 root 管理的位置，不從客戶端接受任何檔案路徑。
                let fm = FileManager.default
                for path in [CPUHelperConstants.launchDaemon, CPUHelperConstants.configuration,
                             CPUHelperConstants.executable] {
                    if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
                }
                try fm.removeItem(atPath: CPUHelperConstants.directory)
                reply(nil)
                self.queue.asyncAfter(deadline: .now() + 0.5) {
                    let bootout = Process()
                    bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    bootout.arguments = ["bootout", "system/" + CPUHelperConstants.label]
                    bootout.standardInput = FileHandle.nullDevice
                    bootout.standardOutput = FileHandle.nullDevice
                    bootout.standardError = FileHandle.nullDevice
                    try? bootout.run()
                }
            } catch { reply("服務移除失敗：\(error.localizedDescription)") }
        }
    }
}

final class CPUClient: NSObject, CPUHelperProtocol {
    let id = UUID()
    let sampler: CPUSampler
    init(sampler: CPUSampler) { self.sampler = sampler }
    func sample(active: Bool, withReply reply: @escaping (Data) -> Void) {
        sampler.sample(client: id, active: active, reply: reply)
    }
    func uninstall(withReply reply: @escaping (String?) -> Void) { sampler.uninstall(reply: reply) }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let sampler = CPUSampler()
    let allowedUID: UInt32
    init(uid: UInt32) { allowedUID = uid }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // UID 由 root 擁有的安裝設定決定；其他使用者不能啟停服務。
        guard connection.effectiveUserIdentifier == allowedUID else { return false }
        let client = CPUClient(sampler: sampler)
        connection.exportedInterface = NSXPCInterface(with: CPUHelperProtocol.self)
        connection.exportedObject = client
        connection.invalidationHandler = { [sampler] in sampler.disconnect(client.id) }
        connection.interruptionHandler = { [sampler] in sampler.disconnect(client.id) }
        connection.resume()
        return true
    }
}

guard geteuid() == 0,
      let attrs = try? FileManager.default.attributesOfItem(atPath: CPUHelperConstants.configuration),
      (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
      (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o644,
      let data = try? Data(contentsOf: URL(fileURLWithPath: CPUHelperConstants.configuration)),
      let configuration = try? JSONDecoder().decode(CPUHelperConfiguration.self, from: data),
      configuration.version == CPUHelperConstants.version, configuration.uid != 0 else { exit(1) }
let delegate = ListenerDelegate(uid: configuration.uid)
let listener = NSXPCListener(machServiceName: CPUHelperConstants.label)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
