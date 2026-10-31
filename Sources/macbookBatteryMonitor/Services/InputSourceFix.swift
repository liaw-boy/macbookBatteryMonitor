import AppKit
import Carbon
import OSLog

/// 中文輸入法的兩個困擾：
/// 1. Caps Lock 切換中英有延遲：macOS 為了防誤觸，Caps Lock 要按住一下才算數。用系統內建的 hidutil 把延遲設成 0
///    （只存在記憶體，所以每次啟動與睡眠喚醒都重設一次）。
/// 2. 按住 Shift 打字母變全形英文：按住 Shift 打第一個字母時暫時切到英文鍵盤，放開 Shift 切回原本的輸入法（判斷在 ShiftHalfWidth）。
///    攔截按鍵需要「輔助使用」權限；開關關掉時完全不攔截
@MainActor
final class InputSourceFix {
    static let shared = InputSourceFix()
    nonisolated static let log = Logger(subsystem: "com.kuan.batterymonitor", category: "inputSource")

    private let tap = ShiftTap()
    /// 切到英文鍵盤前的輸入法，放開 Shift 時切回去
    private var restoreTo: TISInputSource?
    /// 切過去的英文鍵盤；切回前確認還是它，使用者中途自己換了輸入法就不切
    private var switchedToID: String?
    private var sourceObserver: NSObjectProtocol?
    /// 開關打開；監看攔截有沒有被系統暫停或作廢
    private var wanted = false
    private var watchdog: Timer?

    var isRunning: Bool { tap.health() == .ok }

    // MARK: Caps Lock

    /// 把 Caps Lock 延遲設成 0。參數固定，不經過 shell
    static func removeCapsLockDelay() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", #"{"CapsLockDelayOverride":0}"#]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            if process.terminationStatus != 0 { log.error("hidutil 結束碼 \(process.terminationStatus, privacy: .public)") }
        }
        do {
            try process.run()
        } catch {
            log.error("無法執行 hidutil：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Shift 半形

    /// 開始或停止攔截；需要攔截但沒有權限時回傳 false
    @discardableResult
    func applyShift(_ enabled: Bool) -> Bool {
        wanted = enabled
        guard enabled else {
            watchdog?.invalidate()
            watchdog = nil
            // 停止會讓還排在主佇列的動作過期：之後只重送按鍵，不再切輸入法
            tap.stop()
            if let sourceObserver { DistributedNotificationCenter.default().removeObserver(sourceObserver) }
            sourceObserver = nil
            resetPending()
            return true
        }
        if watchdog == nil {
            // 和捲動方向一樣：系統會在逾時、睡眠喚醒或權限變動時暫停甚至作廢攔截，每 5 秒檢查一次
            watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                MainActor.assumeIsolated { InputSourceFix.shared.check() }
            }
        }
        guard AXIsProcessTrusted() else { return false }
        if sourceObserver == nil {
            // 輸入法改變時更新「目前是不是中文輸入法」，攔截執行緒不用自己呼叫 TIS
            sourceObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { InputSourceFix.shared.updateIMEActive() } }
        }
        updateIMEActive()
        if tap.onAction == nil {
            // 只設定一次、之後不再改：舊的攔截執行緒剛好還在讀時也不會讀到改到一半的值
            tap.onAction = { action, event, generation in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { InputSourceFix.shared.perform(action, replay: event, generation: generation) }
                }
            }
            tap.onReset = {
                DispatchQueue.main.async { MainActor.assumeIsolated { InputSourceFix.shared.resetPending() } }
            }
        }
        if tap.health() == .stopped {
            let started = tap.start()
            Self.log.notice("Shift 半形攔截：\(started ? "開始" : "失敗", privacy: .public)")
        }
        return isRunning
    }

    private func check() {
        guard wanted else { return }
        // 上次切回失敗、現在沒在打字：再試一次
        if !holding, backlog.isEmpty, restoreTo != nil, !tap.isSwitched { restore() }
        switch tap.health() {
        case .ok: return
        case .disabled: tap.reenable()
        case .invalid:
            Self.log.notice("Shift 半形攔截已失效，重建")
            tap.stop()
            resetPending()
            applyShift(true)
        case .stopped:
            // 例如剛重新允許「輔助使用」
            applyShift(true)
        }
    }

    private func updateIMEActive() {
        tap.setIMEActive(Self.isChineseIME(TISCopyCurrentKeyboardInputSource().takeRetainedValue()))
    }

    private static func isChineseIME(_ source: TISInputSource) -> Bool {
        let asciiCapable = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable)
            .map { CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue()) } ?? true
        let languages = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
            .flatMap { Unmanaged<CFArray>.fromOpaque($0).takeUnretainedValue() as? [String] } ?? []
        return ShiftHalfWidth.isChineseInputMethod(languages: languages, asciiCapable: asciiCapable)
    }

    /// 切回中文輸入法到真正生效前，後面的按鍵先排隊
    private var holding = false
    private var backlog: [(ShiftHalfWidth.Action, CGEvent?, Int)] = []
    /// 開始排隊時攔截那邊的編號，結束排隊時要對上才算數
    private var holdingGeneration = 0
    /// 每次開始或清掉排隊加一；舊的等待輪詢看到不一樣就停，不會提早送出新排隊的按鍵
    private var holdEpoch = 0
    /// 等切回生效最多等這麼久
    private static let restoreTimeout: TimeInterval = 0.6

    /// 依序在主執行緒做：切輸入法、把攔下來的按鍵重新送出（切到英文鍵盤馬上生效，實測不用等）
    private func perform(_ action: ShiftHalfWidth.Action, replay event: CGEvent?, generation: Int) {
        // 攔截那邊已經放行、停止或重建：只把按鍵送出去，不切輸入法（否則可能停在英文沒人切回）
        guard generation == tap.generation else {
            // 還在排隊：接在後面，由 resetPending 照順序送出，不會插到前面
            if holding { backlog.append((.pass, event, generation)) } else if let event { tap.replay(event, generation: generation) }
            return
        }
        guard !holding else {
            backlog.append((action, event, generation))
            return
        }
        switch action {
        case .switchToASCII:
            let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
            let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
            if TISSelectInputSource(ascii) == noErr {
                // 上次切回失敗還留著目標時保留原本的，不要記成英文鍵盤
                if restoreTo == nil { restoreTo = current }
                switchedToID = Self.id(of: ascii)
            } else {
                Self.log.error("切到英文鍵盤失敗")
            }
            if let event { tap.replay(event, generation: generation) }
        case .restore:
            // 放開 Shift：先送出再切回。漏掉放開、由下一個字觸發時：這個字等切回之後才送出，才會打成注音。
            // 切回生效前攔截那邊也要把後面的按鍵交過來排隊
            let typedKey = event?.type == .keyDown
            // 先把攔截那邊設成排隊，再送出放開 Shift，中間不會有按鍵直接放行
            tap.setHolding(true, generation: generation)
            if let event, !typedKey { tap.replay(event, generation: generation) }
            guard let target = restore() else {
                tap.setHolding(false, generation: generation)
                if let event, typedKey { tap.replay(event, generation: generation) }
                return
            }
            if let event, typedKey { backlog.insert((.pass, event, generation), at: 0) }
            holding = true
            holdingGeneration = generation
            holdEpoch += 1
            waitForSource(target, deadline: CACurrentMediaTime() + Self.restoreTimeout, epoch: holdEpoch)
        case .pass:
            if let event { tap.replay(event, generation: generation) }
        }
    }

    private func waitForSource(_ id: String, deadline: CFTimeInterval, epoch: Int) {
        // 等待中被 resetPending 清掉，或已經換成新的一次排隊
        guard holding, epoch == holdEpoch else { return }
        if Self.id(of: TISCopyCurrentKeyboardInputSource().takeRetainedValue()) == id || CACurrentMediaTime() > deadline {
            drain()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) {
            MainActor.assumeIsolated { InputSourceFix.shared.waitForSource(id, deadline: deadline, epoch: epoch) }
        }
    }

    private func drain() {
        holding = false
        tap.setHolding(false, generation: holdingGeneration)
        var items = backlog[...]
        backlog = []
        while let item = items.popFirst() {
            perform(item.0, replay: item.1, generation: item.2)
            // 又遇到一次切回：剩下的接在新的排隊前面
            if holding {
                // 切回時插在最前面的那個字要維持第一個
                backlog += Array(items)
                return
            }
        }
    }

    /// 切回原本的輸入法，回傳要等它生效的輸入法 ID。
    /// 呼叫前要先送出放開 Shift：實測在「文字編輯」先切回再送出放開時，選單列是注音、打出來卻是英文（原因未確認）
    @discardableResult
    private func restore() -> String? {
        guard let source = restoreTo else { return nil }
        let expected = switchedToID
        // 使用者在這期間自己換了輸入法：尊重他的選擇，不切回（讀不到 ID 時照樣切回）
        if let expected, Self.id(of: TISCopyCurrentKeyboardInputSource().takeRetainedValue()) != expected {
            restoreTo = nil
            switchedToID = nil
            return nil
        }
        guard TISSelectInputSource(source) == noErr else {
            // 保留目標，下次放開 Shift、收尾或每 5 秒的檢查再試
            Self.log.error("切回原本的輸入法失敗")
            return nil
        }
        restoreTo = nil
        switchedToID = nil
        return Self.id(of: source)
    }

    /// 攔截放行、停止或結束 App 時收尾：排隊的按鍵照順序送出、停止等待，切回原本的輸入法
    private func resetPending() {
        let items = backlog
        backlog = []
        holding = false
        holdEpoch += 1
        for (_, event, generation) in items {
            if let event { tap.replay(event, generation: generation) }
        }
        restore()
    }

    private static func id(of source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}

/// 按鍵攔截：在自己的高優先執行緒上跑（和捲動方向一樣），主執行緒忙時打字也不用等。
/// 要切輸入法時把這個按鍵攔下來，交給主執行緒切好再送出；主執行緒還有事沒做完時，後面的按鍵也一起排隊，順序不會亂
final class ShiftTap: @unchecked Sendable {
    /// 自己重新送出的事件帶這個標記，攔截時直接放行
    private static let replayMark: Int64 = 0x5348_4946_5448  // "SHIFTH"

    private let lock = NSLock()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var logic = ShiftHalfWidth()
    private var imeActive = false
    /// 交給主執行緒、還沒送出的按鍵數
    private var queued = 0
    /// 開始排隊的時間；主執行緒卡住太久時攔截這邊自己放行，整台 Mac 的鍵盤不會跟著卡死
    private var queuedSince: CFTimeInterval = 0
    private static let stuckAfter: CFTimeInterval = 1.0
    /// 每次放行、停止、啟動加一；主執行緒拿到舊編號的動作就只送出按鍵
    private var currentGeneration = 0
    /// 只在攔截還沒啟動時設定
    var onAction: ((ShiftHalfWidth.Action, CGEvent?, Int) -> Void)?
    /// 主執行緒卡住、攔截自己放行之後呼叫，讓主執行緒清掉排隊與切回輸入法
    var onReset: (() -> Void)?

    enum Health { case ok, disabled, invalid, stopped }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var generation: Int { locked { currentGeneration } }
    /// 暫時切到英文、還在等放開 Shift
    var isSwitched: Bool { locked { logic.switched } }
    func setIMEActive(_ value: Bool) { locked { imeActive = value } }

    func setHolding(_ on: Bool, generation: Int) {
        locked {
            guard generation == currentGeneration else { return }
            on ? enqueue() : dequeue()
        }
    }

    /// 只在鎖裡呼叫：放棄目前的排隊與狀態
    private func resetLocked() {
        currentGeneration += 1
        queued = 0
        logic = ShiftHalfWidth()
    }

    /// 只在鎖裡呼叫。每送出一個就重新計時：主執行緒慢但還在處理時不算卡住
    private func dequeue() {
        queued = max(0, queued - 1)
        queuedSince = CACurrentMediaTime()
    }

    func health() -> Health {
        guard let port = locked({ self.port }) else { return .stopped }
        guard CFMachPortIsValid(port) else { return .invalid }
        return CGEvent.tapIsEnabled(tap: port) ? .ok : .disabled
    }

    func reenable() {
        if let port = locked({ self.port }) { CGEvent.tapEnable(tap: port, enable: true) }
    }

    /// 只在鎖裡呼叫
    private func enqueue() {
        if queued == 0 { queuedSince = CACurrentMediaTime() }
        queued += 1
    }

    func start() -> Bool {
        guard health() == .stopped else { return health() == .ok }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: mask, callback: shiftTapCallback,
                                               userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                ready.signal()
                return
            }
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            locked {
                self.port = port
                self.runLoop = loop
                resetLocked()
            }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Shift 半形"
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
                resetLocked()
            }
            return (self.port, self.runLoop)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop { CFRunLoopStop(loop) }
    }

    /// 主執行緒切好輸入法後，把攔下來的按鍵送出去
    /// 舊編號的按鍵照樣送出，但不扣現在的排隊數
    func replay(_ event: CGEvent, generation: Int) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.replayMark)
        event.post(tap: .cgSessionEventTap)
        locked { if generation == currentGeneration { dequeue() } }
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // 回應逾時被暫停才自己打開；因使用者輸入被系統暫停時尊重系統，交給每 5 秒的檢查
        if type == .tapDisabledByTimeout { reenable() }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMark { return Unmanaged.passUnretained(event) }
        // 密碼欄等安全輸入：完全不碰
        if IsSecureEventInputEnabled() { return Unmanaged.passUnretained(event) }
        let flags = event.flags
        let input: ShiftHalfWidth.Event?
        switch type {
        case .keyDown:
            input = .keyDown(keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                             shift: flags.contains(.maskShift),
                             otherModifiers: !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty)
        case .flagsChanged where !flags.contains(.maskShift):
            input = .shiftReleased
        default:
            input = nil
        }
        guard let onAction else { return Unmanaged.passUnretained(event) }
        let (action, deferIt, generation, didReset) = locked { () -> (ShiftHalfWidth.Action, Bool, Int, Bool) in
            var didReset = false
            if queued > 0, CACurrentMediaTime() - queuedSince > Self.stuckAfter {
                // 主執行緒沒在處理：放棄排隊、直接放行，鍵盤不會跟著卡死；主執行緒之後收尾（onReset）
                resetLocked()
                didReset = true
            }
            // 不是中文輸入法、也沒切過、沒在排隊：直接放行，不複製事件
            guard imeActive || logic.switched || queued > 0 else { return (.pass, false, currentGeneration, didReset) }
            let action = input.map { logic.handle($0, imeActive: imeActive) } ?? .pass
            let deferIt = action != .pass || queued > 0
            if deferIt { enqueue() }
            return (action, deferIt, currentGeneration, didReset)
        }
        if didReset { onReset?() }
        guard deferIt else { return Unmanaged.passUnretained(event) }
        guard let copy = event.copy() else {
            // 複製失敗：原事件直接放行。已經判斷過的切換照樣交出去（不帶按鍵），狀態才不會亂
            // 這個按鍵不會交給主執行緒送出，先扣掉自己那一份
            setHolding(false, generation: generation)
            if action != .pass { onAction(action, nil, generation) }
            return Unmanaged.passUnretained(event)
        }
        onAction(action, copy, generation)
        return nil
    }
}

private func shiftTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<ShiftTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
}
