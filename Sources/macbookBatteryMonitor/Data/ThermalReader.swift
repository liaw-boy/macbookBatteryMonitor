import Foundation

/// 風扇轉速（AppleSMC）與溫度（IOHIDEventSystem 感測器）。只讀取，不需要管理員權限。
/// HID 感測器用的是私有符號，用 dlsym 取得；macOS 版本不提供時直接當成沒有溫度資料，不會崩潰
final class ThermalReader: @unchecked Sendable {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias FloatValueFn = @convention(c) (AnyObject, Int32) -> Double

    private struct HIDAPI {
        let create: CreateFn
        let setMatching: SetMatchingFn
        let copyServices: CopyServicesFn
        let copyProperty: CopyPropertyFn
        let copyEvent: CopyEventFn
        let floatValue: FloatValueFn
    }

    private static let api: HIDAPI? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: type) } }
        guard let create = symbol("IOHIDEventSystemClientCreate", as: CreateFn.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEventFn.self),
              let floatValue = symbol("IOHIDEventGetFloatValue", as: FloatValueFn.self) else { return nil }
        return HIDAPI(create: create, setMatching: setMatching, copyServices: copyServices,
                      copyProperty: copyProperty, copyEvent: copyEvent, floatValue: floatValue)
    }()

    /// kIOHIDEventTypeTemperature；欄位值是型別左移 16 位元
    private static let temperatureEventType: Int64 = 15
    private static let temperatureField = Int32(15 << 16)

    private let smc = SMC()
    private var fanCount: Int?
    private var client: AnyObject?
    /// (名稱, 服務)；服務清單變化很慢，每分鐘重列一次
    private var sensors: [(name: String, service: AnyObject)] = []
    private var sensorsLoaded: Date?

    /// 這台 Mac 的風扇；沒有風扇（例如 MacBook Air）回傳空陣列
    func fans() -> [FanReading] {
        guard let smc else { return [] }
        if fanCount == nil {
            var count = 0
            while count < 8, smc.hasKey("F\(count)Ac") { count += 1 }
            fanCount = count
        }
        let count = fanCount ?? 0
        return (0..<count).compactMap { index in
            guard let rpm = smc.read("F\(index)Ac") else { return nil }
            let name = count == 2 ? (index == 0 ? "左側風扇" : "右側風扇") : "風扇 \(index + 1)"
            return FanReading(id: index, name: name, rpm: max(0, rpm),
                              minRPM: smc.read("F\(index)Mn") ?? 0, maxRPM: smc.read("F\(index)Mx") ?? 0)
        }
    }

    func temperatures(now: Date = Date()) -> TemperatureSummary {
        guard let api = Self.api else { return TemperatureSummary() }
        if client == nil {
            guard let created = api.create(kCFAllocatorDefault)?.takeRetainedValue() else { return TemperatureSummary() }
            _ = api.setMatching(created, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 0x0005] as CFDictionary)
            client = created
        }
        guard let client else { return TemperatureSummary() }
        if sensorsLoaded.map({ now.timeIntervalSince($0) > 60 }) ?? true {
            let services = api.copyServices(client)?.takeRetainedValue() as [AnyObject]? ?? []
            sensors = services.compactMap { service in
                guard let name = api.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                      ThermalMath.category(for: name) != nil else { return nil }
                return (name, service)
            }
            sensorsLoaded = now
        }
        let readings: [(name: String, value: Double)] = sensors.compactMap { sensor in
            guard let event = api.copyEvent(sensor.service, Self.temperatureEventType, 0, 0)?.takeRetainedValue() else { return nil }
            return (sensor.name, api.floatValue(event, Self.temperatureField))
        }
        return ThermalMath.summary(readings)
    }
}
