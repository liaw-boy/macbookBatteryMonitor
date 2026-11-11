import AppKit
import Carbon
import IOKit.hidsystem
import OSLog

/// Caps Lock 按下就切換中英（實驗，判斷在 CapsLockSwitch）。
/// 順序：先開始攔截 F18，成功後才把 Caps Lock 對應成 F18；停止、沒權限、App 結束時先還原對應，
/// Caps Lock 不會變成沒反應的鍵。攔截在自己的執行緒上跑，主執行緒忙時打字不受影響
@MainActor
final class CapsLockSwitchController {
    static let shared = CapsLockSwitchController()
    nonisolated static let log = Logger(subsystem: "com.kuan.batterymonitor", category: "capsSwitch")

    private let tap = CapsKeyTap()
    private var mapped = false
    var holdSeconds = CapsLockSwitch.defaultHold
    /// 按著沒放；每次按下加一，長按的計時用來確認還是同一次按壓
    private var held = false
    private var press = 0
    private var beforePress: TISInputSource?
    /// 最近用的中文輸入法：從英文切回去時用它
    private var lastChinese: TISInputSource?
    private var sourceObserver: NSObjectProtocol?
    /// 被 kill、登出時送來的結束訊號：預設會直接結束、不跑 applicationWillTerminate，Caps Lock 會一直是 F18
    private var signalSources: [DispatchSourceSignal] = []

    var isRunning: Bool { mapped && tap.health() == .ok }

    /// 打開時開始攔截並對應鍵位；需要「輔助使用」但沒有時停止並回傳 false。可以重複呼叫（每 5 秒的檢查）
    @discardableResult
    func apply(_ enabled: Bool) -> Bool {
        guard enabled, AXIsProcessTrusted() else {
            stop()
            return !enabled
        }
        switch tap.health() {
        case .ok: break
        case .disabled: tap.reenable()
        case .invalid, .stopped:
            tap.stop()
            tap.onKey = { down in
                DispatchQueue.main.async { MainActor.assumeIsolated { CapsLockSwitchController.shared.key(down: down) } }
            }
            guard tap.start() else {
                stop()
                return false
            }
        }
        if !mapped {
            mapped = Self.map()
            if mapped { restoreOnSignals() }
        }
        if sourceObserver == nil {
            sourceObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { CapsLockSwitchController.shared.rememberChinese() } }
            rememberChinese()
        }
        return isRunning
    }

    func stop() {
        if mapped {
            Self.hidutil(["property", "--set", CapsLockSwitch.clearJSON])
            mapped = false
            Self.log.notice("Caps Lock 恢復原本的功能")
        }
        tap.stop()
        held = false
        if let sourceObserver { DistributedNotificationCenter.default().removeObserver(sourceObserver) }
        sourceObserver = nil
    }

    /// 收到結束訊號時先還原 Caps Lock 再正常結束。shortcut: 強制結束（kill -9）和當機攔不到，靠下次啟動時的 clearStaleMapping
    private func restoreOnSignals() {
        guard signalSources.isEmpty else { return }
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    CapsLockSwitchController.shared.stop()
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// hidutil 的設定在睡眠喚醒、鍵盤重新連接後可能被重設
    func reapplyMapping() {
        // 睡眠前按著的那一下不會有放開：不算長按
        held = false
        guard mapped else { return }
        mapped = Self.map()
    }

    /// App 啟動時：上次當掉或被強制結束、對應沒還原，而且這次沒打開功能，就清掉（只清自己的）
    static func clearStaleMapping() {
        guard let output = hidutil(["property", "--get", "UserKeyMapping"]),
              CapsLockSwitch.hasOnlyOurMapping(hidutilOutput: output) else { return }
        hidutil(["property", "--set", CapsLockSwitch.clearJSON])
        log.notice("清掉上次留下的 Caps Lock 對應")
    }

    // MARK: - 按鍵

    private func key(down: Bool) {
        guard down else {
            held = false
            return
        }
        // 不檢查 held：放開可能漏掉（攔截被暫停、密碼欄、睡眠），漏掉後下一次按下仍要有反應；自動重複在攔截那邊已經丟掉
        held = true
        press &+= 1
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        beforePress = current
        select(CapsLockSwitch.target(currentIsEnglish: Self.isEnglish(current)))
        let generation = press
        DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds) {
            MainActor.assumeIsolated { CapsLockSwitchController.shared.longPress(generation) }
        }
    }

    private func longPress(_ generation: Int) {
        guard held, generation == press else { return }
        let result = CapsLockSwitch.longPress(capsLockOn: Self.capsLockOn())
        Self.setCapsLock(result.capsLock)
        if let target = result.source {
            select(target)
        } else if let beforePress {
            FocusedInputSource.select(beforePress)
        }
    }

    private func select(_ target: CapsLockSwitch.Target) {
        let source: TISInputSource?
        switch target {
        case .english: source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        case .chinese: source = lastChinese ?? Self.firstChinese()
        }
        guard let source else {
            Self.log.error("找不到要切換的輸入法")
            return
        }
        FocusedInputSource.select(source)
    }

    private func rememberChinese() {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        if !Self.isEnglish(current) { lastChinese = current }
    }

    // MARK: - 系統

    private static func isEnglish(_ source: TISInputSource) -> Bool {
        TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable)
            .map { CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue()) } ?? true
    }

    /// 還沒切過中文時：清單裡第一個啟用、可選的非英文鍵盤輸入法
    private static func firstChinese() -> TISInputSource? {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        return list.first { !isEnglish($0) }
    }

    /// 大寫鎖定的狀態在 IOHIDSystem（鍵盤燈也跟著它）
    private static func withHIDSystem<T>(_ body: (io_connect_t) -> T?) -> T? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connect) }
        return body(connect)
    }

    private static func capsLockOn() -> Bool {
        withHIDSystem { connect -> Bool? in
            var state = false
            return IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state) == KERN_SUCCESS ? state : nil
        } ?? false
    }

    private static func setCapsLock(_ on: Bool) {
        let result = withHIDSystem { IOHIDSetModifierLockState($0, Int32(kIOHIDCapsLockState), on) }
        if result != KERN_SUCCESS { log.error("無法切換大寫鎖定") }
    }

    /// 已經有別人的鍵位對應時不蓋掉（hidutil 會整個取代）
    private static func map() -> Bool {
        guard let output = hidutil(["property", "--get", "UserKeyMapping"]) else { return false }
        if CapsLockSwitch.hasForeignMapping(hidutilOutput: output) {
            log.error("已有其他鍵位對應，不改 Caps Lock")
            return false
        }
        guard hidutil(["property", "--set", CapsLockSwitch.mappingJSON]) != nil else { return false }
        log.notice("Caps Lock 改成按下就切換中英")
        return true
    }

    /// 參數固定，不經過 shell；成功時回傳輸出
    @discardableResult
    private static func hidutil(_ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log.error("無法執行 hidutil：\(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) ?? "" : nil
    }
}

/// 只處理 F18（對應過的 Caps Lock）：吃掉按下與放開，其他按鍵原樣放行
final class CapsKeyTap: @unchecked Sendable {
    private let lock = NSLock()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    /// 只在攔截停止時設定
    var onKey: ((Bool) -> Void)?

    enum Health { case ok, disabled, invalid, stopped }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func health() -> Health {
        guard let port = locked({ self.port }) else { return .stopped }
        guard CFMachPortIsValid(port) else { return .invalid }
        return CGEvent.tapIsEnabled(tap: port) ? .ok : .disabled
    }

    func reenable() {
        guard AXIsProcessTrusted(), let port = locked({ self.port }) else { return }
        EventTapAccess.shared.reenable(port)
    }

    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop: CFRunLoop = CFRunLoopGetCurrent()
            guard let port = EventTapAccess.shared.createTap(place: .headInsertEventTap, mask: mask, callback: capsKeyTapCallback,
                                                             userInfo: Unmanaged.passUnretained(self).toOpaque(), loop: loop) else {
                ready.signal()
                return
            }
            CGEvent.tapEnable(tap: port, enable: true)
            locked {
                self.port = port
                self.runLoop = loop
            }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Caps Lock 切換"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return health() == .ok
    }

    func stop() {
        let (port, loop) = locked { () -> (CFMachPort?, CFRunLoop?) in
            defer {
                self.port = nil
                self.runLoop = nil
            }
            return (self.port, self.runLoop)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop { CFRunLoopStop(loop) }
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout { reenable() }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // 暫停期間可能漏掉放開：當成已放開，長按計時不會誤開大寫鎖定
            onKey?(false)
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp,
              event.getIntegerValueField(.keyboardEventKeycode) == CapsLockSwitch.f18KeyCode else { return Unmanaged.passUnretained(event) }
        // 按住時系統自動重複的按下不算新的一次
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
        onKey?(type == .keyDown)
        return nil
    }
}

private func capsKeyTapCallback(proxy _: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<CapsKeyTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
}
