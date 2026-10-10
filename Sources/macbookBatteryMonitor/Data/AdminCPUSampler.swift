import Foundation
import Observation
import CPUPowerShared

/// 選用的管理員 CPU 取樣：選項開著才有系統服務，關掉就移除。
/// - 只有使用者在設定裡打開時才要求授權；授權取消或失敗會自動關回選項，開 App 時不會跳出密碼視窗
/// - 只在主面板開啟時連線取樣（每秒，省電模式每 2 秒）；面板關閉立即斷線、不再通訊，服務閒置後自行結束
@MainActor @Observable
final class AdminCPUSampler {
    private(set) var status = "未開啟"
    private(set) var authorizing = false
    @ObservationIgnored var authorizationChanged: ((Bool) -> Void)?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var installLease: URL?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var nextConnectAt: TimeInterval = 0
    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var desiredEnabled: Bool?
    @ObservationIgnored private var desiredActive = false
    @ObservationIgnored private var failed = false
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var lastRequest: TimeInterval = 0
    /// 開始取樣或最後一次拿到有效資料的時間，用來判斷資料逾時
    @ObservationIgnored private var lastFresh: TimeInterval?
    @ObservationIgnored private var reading: CPUPowerReading?
    @ObservationIgnored private var removing = false
    @ObservationIgnored private let helperBundle: Bundle

    private static let idleStatus = "已授權，主面板開啟時才取樣"

    init(bundle: Bundle = .main) { helperBundle = bundle }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    /// 與其他資訊相同的取樣間隔
    private var interval: TimeInterval { AppSettings.shared.sampleInterval }

    /// 每次更新時呼叫（每秒，省電模式每 2 秒）
    func update(active: Bool, enabled: Bool) {
        let launching = desiredEnabled == nil
        let changed = desiredEnabled != enabled
        desiredEnabled = enabled
        let wasActive = desiredActive
        desiredActive = active && enabled
        if changed { failed = false; nextConnectAt = 0 }
        if !desiredActive { reading = nil; lastFresh = nil }
        else if !wasActive { lastFresh = now }

        if !enabled {
            // 啟動時也檢查一次：選項關著卻留有服務（例如上次移除失敗）就順便移除
            if changed { disable() }
            return
        }
        guard !removing, !failed, process == nil else { return }
        if changed {
            if CPUHelperInstaller.installed {
                status = Self.idleStatus
            } else if launching {
                // 開 App 時不自動要求授權：服務不在或版本不符就關掉選項，舊版服務一併移除
                turnOff(CPUHelperInstaller.present ? "CPU 服務已更新，需要時請再開啟此選項並授權。" : "找不到 CPU 服務，已關閉此選項。")
                return
            } else {
                install()
                return
            }
        }
        guard desiredActive else {
            // 面板關閉或進入設定頁：斷線讓服務停止 powermetrics，之後完全不通訊
            if connection != nil { disconnect(); status = Self.idleStatus }
            return
        }
        guard connection != nil else {
            guard now >= nextConnectAt else { return }
            if CPUHelperInstaller.installed { connect(); request() }
            else { turnOff("CPU 服務已被移除，已關閉此選項。") }
            return
        }
        if !inFlight { request() }
        else if now - lastRequest > 5 { fail("CPU 服務沒有回應，請關閉再開啟此選項以重試。") }
    }

    var watts: Double? {
        guard desiredActive else { return nil }
        return reading?.freshWatts(at: now, maxAge: max(3, interval * 2))
    }

    /// 退出 App 時斷線；不移除服務。服務會隨連線結束停止 powermetrics，閒置後自行結束
    func stop() {
        desiredActive = false
        reading = nil
        lastFresh = nil
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
        let token = UUID()
        generation = token
        let client = NSXPCConnection(machServiceName: CPUHelperConstants.label, options: .privileged)
        client.remoteObjectInterface = NSXPCInterface(with: CPUHelperProtocol.self)
        client.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.connection = nil; self.inFlight = false; self.reading = nil
                self.nextConnectAt = ProcessInfo.processInfo.systemUptime + 2
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
    }

    /// 主動斷線：服務端的連線結束回呼會移除租約並停止 powermetrics
    private func disconnect() {
        generation = UUID()
        connection?.invalidate()
        connection = nil
        inFlight = false
        reading = nil
    }

    private func request() {
        guard let connection else { return }
        let token = generation
        let request = UUID()
        requestID = request
        inFlight = true
        lastRequest = now
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token, self.requestID == request, !self.removing else { return }
                self.disconnect()
                self.nextConnectAt = ProcessInfo.processInfo.systemUptime + 2
                self.status = "CPU 服務重新連線中"
            }
        } as? CPUHelperProtocol
        proxy?.sample(active: true, interval: Int(interval)) { [weak self] data in
            Task { @MainActor in
                guard let self, self.generation == token, self.requestID == request, !self.removing else { return }
                self.inFlight = false
                guard let payload = try? JSONDecoder().decode(CPUHelperReply.self, from: data),
                      payload.version == CPUHelperConstants.version else {
                    self.fail("CPU 服務版本不相容，請關閉再開啟此選項。")
                    return
                }
                if let error = payload.error { self.fail(error); return }
                guard self.desiredActive else { self.reading = nil; return }
                self.reading = payload.reading
                if self.watts != nil {
                    self.lastFresh = self.now
                    self.status = self.interval >= 2 ? "每 2 秒取樣中" : "每秒取樣中"
                } else if let lastFresh = self.lastFresh, self.now - lastFresh > 6 {
                    // 切換省電模式時服務會重啟 powermetrics，空檔約 2～3 秒，不算逾時
                    self.fail("CPU 資料已逾時，請關閉再開啟此選項以重試。")
                } else {
                    self.status = "等待 CPU 資料"
                }
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
                    // 授權期間使用者又關掉選項：就算裝好了也立即移除
                    if self.desiredEnabled == false { self.disable(); return }
                    guard succeeded, CPUHelperInstaller.installed else {
                        self.turnOff("授權已取消或安裝失敗，已關閉此選項。")
                        return
                    }
                    self.status = Self.idleStatus
                    if self.desiredActive { self.connect(); self.request() }
                }
            }
            process = task
            authorizing = true
            status = "等待系統管理員授權"
            authorizationChanged?(true)
            try task.run()
        } catch { turnOff("無法安裝 CPU 服務：\(error.localizedDescription)") }
    }

    /// 不經使用者關掉選項（授權取消、服務不見等），讓設定開關與實際狀態一致；留有服務檔案就一併移除
    private func turnOff(_ message: String) {
        stop()
        failed = false
        // 先記成已關閉，下一次 update 才不會當成使用者關閉而覆寫訊息
        desiredEnabled = false
        AppSettings.shared.adminCPUSampling = false
        if CPUHelperInstaller.present { disable(finalStatus: message) } else { status = message }
    }

    private func disable(finalStatus: String = "已關閉並移除 CPU 服務") {
        reading = nil
        desiredActive = false
        // 授權進行中：先取消，安裝程序結束的回呼看到選項已關會再移除，避免留下孤兒服務
        if let process {
            if let installLease { try? FileManager.default.removeItem(at: installLease) }
            if process.isRunning { process.terminate() }
            status = "正在取消授權"
            return
        }
        guard CPUHelperInstaller.present else { stop(); status = "未開啟"; return }
        disconnect()
        connect()
        guard let connection else { return }
        removing = true
        let token = generation
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.removing = false
                self.stop()
                self.status = "服務移除失敗，請開啟後再關閉此選項重試。"
            }
        } as? CPUHelperProtocol
        proxy?.uninstall { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.removing = false
                self.stop()
                self.status = error ?? finalStatus
                // 移除期間使用者又打開選項：服務已經不在，關回選項，需要時再開一次授權
                if self.desiredEnabled == true {
                    self.desiredEnabled = false
                    AppSettings.shared.adminCPUSampling = false
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
