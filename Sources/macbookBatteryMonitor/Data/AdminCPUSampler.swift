import Foundation
import Observation
import CPUPowerShared

/// 安裝授權與取樣分離：暫停面板只停止取樣，設定關閉才移除系統服務。
@MainActor @Observable
final class AdminCPUSampler {
    private(set) var status = "尚未啟用"
    private(set) var authorizing = false
    @ObservationIgnored var authorizationChanged: ((Bool) -> Void)?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var installLease: URL?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var nextConnectAt: TimeInterval = 0
    @ObservationIgnored private var installedOnce = false
    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var desiredEnabled: Bool?
    @ObservationIgnored private var desiredActive = false
    @ObservationIgnored private var failed = false
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var lastRequest: TimeInterval = 0
    @ObservationIgnored private var firstActive: TimeInterval?
    @ObservationIgnored private var reading: CPUPowerReading?
    @ObservationIgnored private var removing = false
    @ObservationIgnored private let helperBundle: Bundle

    init(bundle: Bundle = .main) { helperBundle = bundle }

    func update(active: Bool, enabled: Bool) {
        let changed = desiredEnabled != enabled
        desiredEnabled = enabled
        let wasActive = desiredActive
        desiredActive = active && enabled
        if changed { failed = false; installedOnce = false; nextConnectAt = 0 }
        if !desiredActive { reading = nil; firstActive = nil }
        else if !wasActive { firstActive = ProcessInfo.processInfo.systemUptime }
        if !enabled {
            if changed { disable() }
            return
        }
        guard !removing, !failed else { return }
        guard connection != nil else {
            if process == nil && ProcessInfo.processInfo.systemUptime >= nextConnectAt {
                if CPUHelperInstaller.installed { connect() }
                else if installedOnce { fail("CPU 服務已移除，請關閉再開啟此選項以重新授權。") }
                else { install() }
            }
            return
        }
        // 暫停不必等待尚未完成的取樣回覆；舊回覆會檢查目前的 active intent。
        if wasActive && !desiredActive { request(active: false); return }
        if !inFlight { request(active: desiredActive) }
        else if ProcessInfo.processInfo.systemUptime - lastRequest > 5 {
            fail("CPU 服務沒有回應，請關閉再開啟此選項以重試。")
        }
    }

    var watts: Double? {
        guard desiredActive else { return nil }
        return reading?.freshWatts(at: ProcessInfo.processInfo.systemUptime)
    }

    /// 退出 App 時斷線；不移除持久授權。服務會隨連線結束停止子程序。
    func stop() {
        desiredActive = false
        reading = nil
        firstActive = nil
        generation = UUID()
        if let installLease { try? FileManager.default.removeItem(at: installLease) }
        installLease = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        connection?.invalidate()
        connection = nil
        inFlight = false
        if authorizing { authorizing = false; authorizationChanged?(false) }
    }

    private func connect() {
        installedOnce = true
        let token = UUID()
        generation = token
        let client = NSXPCConnection(machServiceName: CPUHelperConstants.label, options: .privileged)
        client.remoteObjectInterface = NSXPCInterface(with: CPUHelperProtocol.self)
        client.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.connection = nil; self.inFlight = false; self.reading = nil
                if !self.removing && !self.failed { self.status = "服務連線中斷，將重新連線" }
            }
        }
        client.interruptionHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.reading = nil; self.inFlight = false
            }
        }
        connection = client
        client.resume()
        if desiredActive { firstActive = ProcessInfo.processInfo.systemUptime }
        request(active: desiredActive)
    }

    private func request(active: Bool) {
        guard let connection else { return }
        let token = generation
        let request = UUID()
        requestID = request
        inFlight = true
        lastRequest = ProcessInfo.processInfo.systemUptime
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token, self.requestID == request, !self.removing else { return }
                self.generation = UUID()
                self.connection?.invalidate()
                self.connection = nil
                self.inFlight = false
                self.reading = nil
                self.nextConnectAt = ProcessInfo.processInfo.systemUptime + 2
                self.status = "CPU 服務重新連線中"
            }
        } as? CPUHelperProtocol
        proxy?.sample(active: active) { [weak self] data in
            Task { @MainActor in
                guard let self, self.generation == token, self.requestID == request, !self.removing else { return }
                self.inFlight = false
                guard let payload = try? JSONDecoder().decode(CPUHelperReply.self, from: data),
                      payload.version == CPUHelperConstants.version else {
                    self.fail("CPU 服務版本不相容，請重新啟用功能。")
                    return
                }
                if let error = payload.error { self.fail(error); return }
                guard self.desiredActive else {
                    self.reading = nil
                    self.status = "已授權，主面板開啟時取樣"
                    return
                }
                self.reading = payload.reading
                if self.watts != nil { self.status = "每秒取樣中" }
                else if let firstActive = self.firstActive,
                        ProcessInfo.processInfo.systemUptime - firstActive > 5 {
                    self.fail("CPU 資料已逾時，請關閉再開啟此選項以重試。")
                } else { self.status = "等待第一筆 CPU 資料" }
            }
        }
    }

    private func install() {
        let token = UUID()
        generation = token
        do {
            let lease = FileManager.default.temporaryDirectory.appendingPathComponent("cpu-install-\(UUID().uuidString)")
            try Data().write(to: lease, options: .atomic)
            installLease = lease
            let task = try CPUHelperInstaller.makeProcess(bundle: helperBundle, lease: lease)
            task.terminationHandler = { [weak self] task in
                let succeeded = task.terminationStatus == 0
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.process = nil
                    if let lease = self.installLease { try? FileManager.default.removeItem(at: lease) }
                    self.installLease = nil
                    self.authorizing = false
                    self.authorizationChanged?(false)
                    if self.desiredEnabled == false { self.disable(); return }
                    guard succeeded, CPUHelperInstaller.installed else {
                        self.fail("授權取消或服務安裝失敗，請關閉再開啟此選項以重試。")
                        return
                    }
                    if self.desiredEnabled == true { self.connect() }
                    else { self.disable() }
                }
            }
            process = task
            authorizing = true
            status = "等待系統管理員授權（首次啟用）"
            authorizationChanged?(true)
            try task.run()
        } catch { fail("無法安裝 CPU 服務：\(error.localizedDescription)") }
    }

    private func disable() {
        reading = nil
        desiredActive = false
        // 授權進行中先保留完成回呼：若安裝已經開始，完成後立即移除，避免留下孤兒服務。
        if let process {
            if let installLease { try? FileManager.default.removeItem(at: installLease) }
            if process.isRunning { process.terminate() }
            status = "正在取消授權與停用服務"
            return
        }
        guard CPUHelperInstaller.installed else {
            stop(); status = "尚未啟用"; return
        }
        if connection == nil { connect() }
        guard let connection else { return }
        removing = true
        let token = generation
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.removing = false
                self.fail("服務移除失敗，請重新啟用後再關閉。")
            }
        } as? CPUHelperProtocol
        proxy?.uninstall { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.removing = false
                self.stop()
                self.status = error ?? "已停用並移除 CPU 服務"
                self.failed = error != nil
                if self.desiredEnabled == true && error == nil {
                    self.status = "請關閉再開啟此選項以重新授權。"
                    self.failed = true
                }
            }
        }
    }

    private func fail(_ message: String) {
        stop()
        failed = true
        status = message
    }
}
