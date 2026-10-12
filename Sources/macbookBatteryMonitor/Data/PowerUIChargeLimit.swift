import Foundation

/// macOS 的充電上限服務（系統私有框架 PowerUI 的 PowerUISmartChargeClient，系統設定的電池頁也是用它）。
/// 用 Objective-C runtime 動態呼叫，這台 Mac 或系統版本沒有這些方法、或回報不支援時視為不支援（Intel、macOS 26 以前）。
/// 每次呼叫都是同步的跨程序請求，放在 actor 裡執行，不卡住畫面
actor PowerUIChargeLimit {
    struct Reading: Equatable, Sendable {
        /// 目前設定的上限，100 表示不限制
        var limit: Int
        /// false 表示有設定上限但系統目前沒有套用
        var enabled: Bool
        var options: [Int]
    }

    enum SetOutcome: Sendable {
        case applied(Reading)
        /// 系統拒絕或沒有套用；附上錯誤代碼與調整後讀回的值
        case rejected(code: Int?, after: Reading?)
    }

    private static let frameworkPath = "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI"
    private static let requiredSelectors = ["initWithClientName:", "isMCLSupported", "getMCLLimitWithError:",
                                            "isMCLCurrentlyEnabled:", "availableChargeLimitsWithError:", "setMCLLimit:error:"]

    private typealias BoolFn = @convention(c) (AnyObject, Selector) -> Bool
    private typealias UInt8Fn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> UInt8
    private typealias UInt64Fn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> UInt64
    private typealias ObjectFn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
    private typealias SetFn = @convention(c) (AnyObject, Selector, UInt8, AutoreleasingUnsafeMutablePointer<NSError?>) -> Bool

    private var client: NSObject?
    private var loaded = false

    /// 不支援或讀取失敗時回傳 nil
    func read() -> Reading? {
        guard let client = instance(),
              let getLimit = method(client, "getMCLLimitWithError:", as: UInt8Fn.self),
              let isEnabled = method(client, "isMCLCurrentlyEnabled:", as: UInt64Fn.self),
              let available = method(client, "availableChargeLimitsWithError:", as: ObjectFn.self) else { return nil }
        return autoreleasepool {
            var error: NSError?
            let raw = getLimit.call(client, getLimit.selector, &error)
            guard error == nil else { return nil }
            let enabled = isEnabled.call(client, isEnabled.selector, &error)
            let options = available.call(client, available.selector, &error) as? [Any]
            return Reading(limit: ChargeLimitLogic.normalized(Int(raw)), enabled: enabled == 1,
                           options: ChargeLimitLogic.options(from: options))
        }
    }

    /// 寫入新的上限，再讀回來確認系統真的套用了
    func set(_ limit: Int) async -> SetOutcome {
        guard let client = instance(), let setter = method(client, "setMCLLimit:error:", as: SetFn.self),
              (0...100).contains(limit) else { return .rejected(code: nil, after: nil) }
        var code: Int?
        let accepted = autoreleasepool {
            var error: NSError?
            let ok = setter.call(client, setter.selector, UInt8(limit), &error)
            code = error?.code
            return ok && error == nil
        }
        guard accepted else { return .rejected(code: code, after: read()) }
        // 系統可能稍後才更新讀到的值，對不上就再等一下
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 300_000_000) }
            if let after = read(), after.limit == limit { return .applied(after) }
        }
        return .rejected(code: nil, after: read())
    }

    private func instance() -> NSObject? {
        if loaded { return client }
        loaded = true
        guard dlopen(Self.frameworkPath, RTLD_NOW) != nil,
              let type = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type,
              Self.requiredSelectors.allSatisfy({ type.instancesRespond(to: NSSelectorFromString($0)) }),
              // alloc 的 +1 交給 init，init 回傳的物件由這裡持有
              let allocated = type.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              let created = allocated.perform(NSSelectorFromString("initWithClientName:"), with: "macbookBatteryMonitor")?
                .takeRetainedValue() as? NSObject,
              let supported = method(created, "isMCLSupported", as: BoolFn.self),
              supported.call(created, supported.selector) else { return nil }
        client = created
        return created
    }

    private func method<T>(_ object: NSObject, _ name: String, as type: T.Type) -> (call: T, selector: Selector)? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return (unsafeBitCast(object.method(for: selector), to: type), selector)
    }
}
