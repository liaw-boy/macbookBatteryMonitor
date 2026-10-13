import AppKit

if CommandLine.arguments.contains("--dump-monitors") {
    MainActor.assumeIsolated { MonitorDebug.dump() }
    exit(0)
}

/// 開發用：讀一次周邊設備電量（含所有藍牙設備）並印出
if CommandLine.arguments.contains("--dump-peripherals") {
    let start = Date()
    let services = PeripheralReader.hidServices()
    let audio = PeripheralReader.bluetoothAudioConnected()
    // 藍牙低功耗設備（羅技、Razer 等）：要從 .app 啟動才會用這個 App 的藍牙權限；最多等 6 秒讀到電量
    if !BLEBatteryReader.denied {
        BLEBatteryReader.shared.start()
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, BLEBatteryReader.shared.currentReadings().isEmpty { Thread.sleep(forTimeInterval: 0.3) }
    }
    print("藍牙權限：\(BLEBatteryReader.authorized ? "已允許" : BLEBatteryReader.denied ? "已拒絕" : "尚未決定")・藍牙低功耗電量 \(BLEBatteryReader.shared.currentReadings().count) 個")
    let devices = PeripheralReader.read(includeAllBluetooth: true)
    print("HID 電量服務 \(services.count) 個・藍牙音訊裝置連線中：\(audio)・耗時 \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    for device in devices {
        print("\(device.name)（\(device.kind.rawValue)）\(device.lowest.map { "\($0)%" } ?? "—") \(device.detailText ?? "")")
    }
    if devices.isEmpty { print("沒有連線中、會回報電量的周邊設備") }
    exit(0)
}

/// 開發用：每秒印一份感測器表格，可接次數，例如 --dump-sensors 10
if let index = CommandLine.arguments.firstIndex(of: "--dump-sensors") {
    let next = CommandLine.arguments.dropFirst(index + 1).first
    SensorDump.run(count: min(600, max(1, next.flatMap { Int($0) } ?? 1)))
    exit(0)
}

if CommandLine.arguments.contains("--dump-hardware") {
    DumpCommand.runHardware()
    exit(0)
}

if CommandLine.arguments.contains("--dump") {
    DumpCommand.run()
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--screenshots"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        ScreenshotCommand.run(directory: CommandLine.arguments[index + 1])
    }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        SnapshotCommand.run(directory: CommandLine.arguments[index + 1])
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
