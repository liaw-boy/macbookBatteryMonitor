import AppKit
import CoreAudio
import Observation
import OSLog

/// 各 App 分開調音量（判斷與混音在 AppVolume）。
/// 用 macOS 14.2 起的程序音訊擷取（Core Audio process tap），不裝驅動程式：
/// 只有調低或靜音的 App 才擷取，把它原本的聲音靜音，乘上音量後從目前的輸出裝置播出；回到 100% 就整個拆掉。
/// 做法參考 fader（MIT，https://github.com/pantafive/fader）的說明與流程，程式自己寫。
/// 讀寫 Core Audio 都是同步的程序間呼叫，全部放在 queue 上，不卡主執行緒
@MainActor
@Observable
final class AppVolumeController {
    static let shared = AppVolumeController()
    nonisolated static let log = Logger(subsystem: "com.kuan.batterymonitor", category: "appVolume")

    struct PlayingApp: Equatable, Identifiable {
        var bundleID: String
        var name: String
        var id: String { bundleID }
    }

    /// 正在發出聲音的 App（面板打開時更新）
    private(set) var playing: [PlayingApp] = []
    private(set) var settings: [String: AppVolume.Setting] = [:]
    /// 沒有「系統錄音」權限，或擷取一直收到無聲資料：已經全部停掉，App 恢復原本的音量
    private(set) var problem = false

    @ObservationIgnored private let engine = AppVolumeEngine()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var panelVisible = false
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var signalSources: [DispatchSourceSignal] = []
    @ObservationIgnored var onSettingsChange: (([String: AppVolume.Setting]) -> Void)?

    static var supported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// 打開或關掉功能；settings 是存起來的各 App 音量
    func apply(enabled: Bool, settings stored: [String: AppVolume.Setting]) {
        settings = stored
        self.enabled = enabled && Self.supported
        guard self.enabled else {
            timer?.invalidate()
            timer = nil
            playing = []
            engine.queue.async { [engine] in engine.removeAll() }
            return
        }
        if wakeObserver == nil {
            // 喚醒後輸出裝置可能換了：馬上和一秒後各同步一次
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    AppVolumeController.shared.sync()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { AppVolumeController.shared.sync() } }
                }
            }
            restoreOnSignals()
            engine.queue.async { [engine] in engine.listenForDeviceChanges() }
        }
        sync()
        updateTimer()
    }

    /// 面板打開時列出正在播放的 App；關掉後只在有調整過的 App 時才繼續檢查
    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        if visible { sync() }
        updateTimer()
    }

    func setting(for bundleID: String) -> AppVolume.Setting { settings[bundleID] ?? AppVolume.Setting() }

    func setVolume(_ volume: Double, for bundleID: String) {
        var setting = self.setting(for: bundleID)
        setting.volume = AppVolume.clamp(volume)
        update(setting, for: bundleID)
    }

    func toggleMute(_ bundleID: String) {
        var setting = self.setting(for: bundleID)
        setting.muted.toggle()
        update(setting, for: bundleID)
    }

    /// 權限或無聲資料的問題處理後再試一次
    func retry() {
        problem = false
        engine.queue.async { [engine] in engine.resetProblem() }
        sync()
    }

    /// App 結束前拆掉所有擷取，被擷取的 App 立刻恢復原本的聲音
    func stopAll() {
        engine.queue.sync { engine.removeAll() }
    }

    private func update(_ setting: AppVolume.Setting, for bundleID: String) {
        if setting.needsTap { settings[bundleID] = setting } else { settings[bundleID] = nil }
        onSettingsChange?(settings)
        // 拖動滑桿時只改音量，不用重建擷取
        if let gain = settings[bundleID]?.gain {
            engine.queue.async { [engine] in engine.setGain(gain, for: bundleID) }
        }
        sync()
        updateTimer()
    }

    private func updateTimer() {
        let needed = enabled && (panelVisible || settings.values.contains(where: \.needsTap))
        if needed, timer == nil {
            // shortcut: 每 2 秒輪詢一次程序清單（Core Audio 的「正在輸出」通知在 macOS 26 起不會觸發）；有通知可靠的版本再改成事件驅動
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated { AppVolumeController.shared.sync() }
            }
        } else if !needed {
            timer?.invalidate()
            timer = nil
        }
    }

    private func sync() {
        guard enabled else { return }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
        let names = Dictionary(apps.compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }, uniquingKeysWith: { first, _ in first })
        let pidOwners = Dictionary(apps.compactMap { app in app.bundleIdentifier.map { (app.processIdentifier, $0) } }, uniquingKeysWith: { first, _ in first })
        let targets = settings.filter { $0.value.needsTap }.mapValues(\.gain)
        engine.queue.async { [engine] in
            let result = engine.sync(targets: targets, pidOwners: pidOwners, appIDs: Set(names.keys))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let controller = AppVolumeController.shared
                    let list = result.playing.sorted().map { PlayingApp(bundleID: $0, name: names[$0] ?? $0) }
                    if controller.playing != list { controller.playing = list }
                    if controller.problem != result.problem { controller.problem = result.problem }
                }
            }
        }
    }

    /// 被 kill、登出時送來的結束訊號：先拆掉擷取，被擷取的 App 不會停在靜音。shortcut: kill -9 攔不到，靠系統在本程序結束時收回擷取
    private func restoreOnSignals() {
        guard signalSources.isEmpty else { return }
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    AppVolumeController.shared.stopAll()
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

/// 在自己的 queue 上管理每個 App 的擷取（只能在 queue 上呼叫）
final class AppVolumeEngine: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.kuan.batterymonitor.appVolume", qos: .userInitiated)
    private var taps: [String: AppTap] = [:]
    private var problem = false
    private var listening = false

    struct Result {
        var playing: Set<String>
        var problem: Bool
    }

    func resetProblem() { problem = false }

    func setGain(_ gain: Float, for bundleID: String) { taps[bundleID]?.setGain(gain) }

    func removeAll() {
        for tap in taps.values { tap.invalidate() }
        taps = [:]
    }

    /// 依目前的程序清單建立、重建或拆掉擷取，回傳正在發出聲音的 App
    func sync(targets: [String: Float], pidOwners: [pid_t: String], appIDs: Set<String>) -> Result {
        let processes = AudioProcess.all()
        var objects: [String: Set<AudioObjectID>] = [:]
        var playing = Set<String>()
        for process in processes where process.pid != getpid() {
            guard let owner = pidOwners[process.pid] ?? AppVolume.owner(ofProcessBundleID: process.bundleID, apps: appIDs) else { continue }
            objects[owner, default: []].insert(process.objectID)
            if process.isRunningOutput { playing.insert(owner) }
        }
        // 不再需要、或 App 已經沒有程序的：拆掉，聲音回到原本的樣子
        for (bundleID, tap) in taps where targets[bundleID] == nil || objects[bundleID] == nil {
            tap.invalidate()
            taps[bundleID] = nil
        }
        // 擷取一直收到無聲資料（多半是沒有系統錄音權限）：全部拆掉，不讓 App 被靜音卻只播出無聲
        if taps.values.contains(where: \.receivesOnlySilence) {
            AppVolumeController.log.error("擷取一直收到無聲資料，停止各 App 音量")
            problem = true
        }
        if problem {
            removeAll()
            return Result(playing: playing, problem: true)
        }
        let output = AudioProcess.defaultOutputUID()
        for (bundleID, gain) in targets {
            guard let ids = objects[bundleID], let output else { continue }
            if let tap = taps[bundleID], tap.processObjects == ids, tap.outputUID == output, tap.isAlive {
                tap.setGain(gain)
                continue
            }
            // 程序清單（例如瀏覽器新開了 Helper）或輸出裝置變了：重建
            taps[bundleID]?.invalidate()
            let tap = AppTap(processObjects: ids, outputUID: output, gain: gain)
            switch tap.activate() {
            case .ok: taps[bundleID] = tap
            case .permissionDenied:
                AppVolumeController.log.error("沒有系統錄音權限，停止各 App 音量")
                tap.invalidate()
                problem = true
                removeAll()
                return Result(playing: playing, problem: true)
            case .failed:
                tap.invalidate()
            }
        }
        return Result(playing: playing, problem: false)
    }

    /// 預設輸出裝置換了、或 Core Audio 重新啟動：全部重建
    func listenForDeviceChanges() {
        guard !listening else { return }
        listening = true
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyServiceRestarted] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { [weak self] _, _ in
                self?.removeAll()
                DispatchQueue.main.async { MainActor.assumeIsolated { AppVolumeController.shared.retryAfterDeviceChange() } }
            }
        }
    }
}

extension AppVolumeController {
    fileprivate func retryAfterDeviceChange() { sync() }
}

/// 一個 App 的擷取：擷取（靜音原本的聲音）→ 私有聚合裝置（擷取＋實際的輸出裝置）→ 音訊回呼
final class AppTap: @unchecked Sendable {
    enum Activation { case ok, permissionDenied, failed }

    let processObjects: Set<AudioObjectID>
    let outputUID: String
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.kuan.batterymonitor.appVolume.io", qos: .userInteractive)
    private let started = Date()
    // 音訊執行緒只讀寫這幾個值：32 位元對齊的讀寫不會讀到一半
    private var targetGain: Float
    private var currentGain: Float
    private var ramp: Float = 1
    private var heardSound = false

    init(processObjects: Set<AudioObjectID>, outputUID: String, gain: Float) {
        self.processObjects = processObjects
        self.outputUID = outputUID
        targetGain = gain
        currentGain = gain
    }

    func setGain(_ gain: Float) { targetGain = gain }

    /// 開始超過 5 秒，App 說它正在輸出，卻從來沒收到任何聲音
    var receivesOnlySilence: Bool { !heardSound && Date().timeIntervalSince(started) > 5 && AudioProcess.anyRunningOutput(processObjects) }

    var isAlive: Bool {
        guard aggregateID != kAudioObjectUnknown else { return false }
        return AudioProcess.read(aggregateID, kAudioDevicePropertyDeviceIsAlive, default: UInt32(0)) != 0
    }

    func activate() -> Activation {
        guard #available(macOS 14.2, *) else { return .failed }
        let description = CATapDescription(stereoMixdownOfProcesses: Array(processObjects))
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        if status == kAudioDevicePermissionsError { return .permissionDenied }
        guard status == noErr else {
            AppVolumeController.log.error("無法建立擷取：\(status, privacy: .public)")
            return .failed
        }
        tapID = tap
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "App 音量",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            // 私有：只有本程序看得到，不會出現在系統的聲音設定裡，本程序結束就消失
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        if status == kAudioDevicePermissionsError { return .permissionDenied }
        guard status == noErr else {
            AppVolumeController.log.error("無法建立聚合裝置：\(status, privacy: .public)")
            return .failed
        }
        aggregateID = device
        // 只處理 Float32：其他格式不擷取，免得 App 被靜音卻沒有聲音出來
        guard let rate = AudioProcess.float32SampleRate(device) else {
            AppVolumeController.log.error("輸出格式不是 Float32，不調整這個 App")
            return .failed
        }
        ramp = AppVolume.rampCoefficient(sampleRate: rate)
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, ioQueue) { @Sendable [unowned(unsafe) self] _, input, _, output, _ in
            self.render(input, output)
        }
        guard status == noErr, let proc else { return .failed }
        procID = proc
        guard AudioDeviceStart(device, proc) == noErr else { return .failed }
        AppVolumeController.log.notice("開始調整 \(self.processObjects.count) 個程序的音量")
        return .ok
    }

    /// 依序拆掉：停止 → 回呼 → 聚合裝置 → 擷取；拆掉擷取後 App 恢復原本的聲音
    func invalidate() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { invalidate() }

    // 音訊執行緒：不配置記憶體、不上鎖、不寫記錄
    private func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var gain = currentGain
        for (index, buffer) in UnsafeMutableAudioBufferListPointer(output).enumerated() {
            guard let out = buffer.mData else { continue }
            let outSamples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard index < inputs.count, let data = inputs[index].mData else {
                memset(out, 0, Int(buffer.mDataByteSize))
                continue
            }
            let result = AppVolume.mix(input: data.assumingMemoryBound(to: Float.self), inputChannels: Int(inputs[index].mNumberChannels),
                                       inputSamples: Int(inputs[index].mDataByteSize) / MemoryLayout<Float>.size,
                                       output: out.assumingMemoryBound(to: Float.self), outputChannels: Int(buffer.mNumberChannels),
                                       outputSamples: outSamples, gain: gain, target: targetGain, ramp: ramp)
            gain = result.gain
            if result.peak > 0 { heardSound = true }
        }
        currentGain = gain
    }
}

/// Core Audio 裡的程序與裝置（只能在 AppVolumeEngine.queue 上呼叫）
enum AudioProcess {
    struct Info {
        var objectID: AudioObjectID
        var pid: pid_t
        var bundleID: String
        var isRunningOutput: Bool
    }

    static func all() -> [Info] {
        guard #available(macOS 14.2, *) else { return [] }
        let ids: [AudioObjectID] = readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        return ids.map { id in
            Info(objectID: id, pid: read(id, kAudioProcessPropertyPID, default: pid_t(-1)),
                 bundleID: readString(id, kAudioProcessPropertyBundleID) ?? "",
                 isRunningOutput: read(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0)
        }
    }

    static func anyRunningOutput(_ ids: Set<AudioObjectID>) -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        return ids.contains { read($0, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0 }
    }

    static func defaultOutputUID() -> String? {
        let device: AudioObjectID = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
        guard device != kAudioObjectUnknown else { return nil }
        return readString(device, kAudioDevicePropertyDeviceUID)
    }

    /// 聚合裝置的輸出格式是 Float32 時回傳取樣率
    static func float32SampleRate(_ device: AudioObjectID) -> Double? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &format) == noErr,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mSampleRate > 0 else { return nil }
        return format.mSampleRate
    }

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) -> T {
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        return status == noErr ? result : value
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func readArray(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
}
