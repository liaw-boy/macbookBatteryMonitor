import AppKit

/// 這台 Mac 的處理器
enum ChipInfo {
    /// 例如 "Apple M2 Pro"、"Intel(R) Core(TM) i5-8500B CPU @ 3.00GHz"
    static let brand: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }()

    static let isIntel = brand.hasPrefix("Intel")
}

extension ChipInfo {
    /// 介面用的簡短名稱："Intel(R) Core(TM) i5-8500B CPU @ 3.00GHz" → "Intel Core i5-8500B"
    static var shortName: String {
        var name = brand.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "(TM)", with: "")
        if let at = name.range(of: " @") { name = String(name[..<at.lowerBound]) }
        name = name.replacingOccurrences(of: " CPU", with: "")
        return name.split(separator: " ").joined(separator: " ")
    }

    /// 機型代號，例如 "Macmini8,1"、"Mac14,3"
    static let model: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }()
}

extension ChipInfo {
    /// 有沒有內建螢幕（MacBook、iMac）；機型固定，只判斷一次
    @MainActor static let hasBuiltInDisplay: Bool = NSScreen.screens.contains { screen in
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
    }
}
