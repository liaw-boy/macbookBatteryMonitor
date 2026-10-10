import Foundation

final class PeripheralTests {
    /// system_profiler SPBluetoothDataType -json 的格式（示範數據）
    private let sample = """
    {"SPBluetoothDataType":[{"controller_properties":{"controller_state":"attrib_on"},
     "device_connected":[
      {"AirPods Pro":{"device_address":"A1:B2:C3:D4:E5:F6","device_batteryLevelCase":"45%",
        "device_batteryLevelLeft":"80%","device_batteryLevelRight":"76%","device_minorType":"Headphones"}},
      {"Magic Mouse":{"device_address":"11:22:33:44:55:66","device_batteryLevelMain":"64%","device_minorType":"Mouse"}},
      {"Speaker":{"device_address":"99:88:77:66:55:44","device_minorType":"Speaker"}}],
     "device_not_connected":[{"Old Keyboard":{"device_address":"AA:AA:AA:AA:AA:AA","device_batteryLevelMain":"50%"}}]}]}
    """

    func testBluetoothParsing() {
        let devices = PeripheralParse.bluetooth(json: Data(sample.utf8))
        // 只列連線中、有回報電量的設備
        XCTAssertEqual(devices.map(\.name), ["AirPods Pro", "Magic Mouse"])
        let pods = devices[0]
        XCTAssertEqual(pods.kind, .headphones)
        XCTAssertEqual(pods.left, 80)
        XCTAssertEqual(pods.right, 76)
        XCTAssertEqual(pods.caseLevel, 45)
        XCTAssertEqual(pods.lowest, 76)
        XCTAssertEqual(pods.detailText, "左 80%・右 76%・盒 45%")
        XCTAssertEqual(pods.symbol, "airpodspro")
        XCTAssertEqual(devices[1].level, 64)
        XCTAssertEqual(devices[1].id, "11:22:33:44:55:66")
        XCTAssertTrue(PeripheralParse.bluetooth(json: Data("not json".utf8)).isEmpty)
    }

    func testHIDMergeAndDedupe() {
        let hid = PeripheralParse.hid([
            ["Product": "Magic Mouse", "BatteryPercent": 63, "DeviceAddress": "11-22-33-44-55-66"],
            // 同一個設備的第二個 HID 服務
            ["Product": "Magic Mouse", "BatteryPercent": 63, "DeviceAddress": "11-22-33-44-55-66"],
            ["Product": "Magic Keyboard", "BatteryPercent": 88, "DeviceAddress": "77-77-77-77-77-77"],
            ["Product": "Broken", "BatteryPercent": 140],
        ])
        XCTAssertEqual(hid.count, 2)
        XCTAssertEqual(hid[1].kind, .keyboard)
        let merged = PeripheralParse.merge(hid: hid, bluetooth: PeripheralParse.bluetooth(json: Data(sample.utf8)))
        XCTAssertEqual(merged.map(\.name), ["AirPods Pro", "Magic Keyboard", "Magic Mouse"])
        // 兩邊都有時用 system_profiler 的電量與名稱，不重複列出
        XCTAssertEqual(merged.first { $0.name == "Magic Mouse" }?.level, 64)
        XCTAssertEqual(PeripheralParse.normalizedAddress("AA-bb-CC-dd-EE-ff"), "aa:bb:cc:dd:ee:ff")
    }

    func testPerDeviceAlerts() {
        var alerts = PeripheralAlerts()
        var mouse = PeripheralBattery(id: "mouse", name: "Magic Mouse", kind: .mouse, level: 25)
        let pods = PeripheralBattery(id: "pods", name: "AirPods", kind: .headphones, left: 9, right: 40)
        let thresholds = ["mouse": 20, "pods": 10]
        func run(_ devices: [PeripheralBattery]) -> [String] {
            alerts.evaluate(devices) { thresholds[$0] ?? 20 }.map(\.id)
        }
        // 耳機以左右耳較低的那一邊判斷
        XCTAssertEqual(run([mouse, pods]), ["pods"])
        XCTAssertEqual(run([mouse, pods]), [])
        mouse.level = 20
        XCTAssertEqual(run([mouse, pods]), ["mouse"])
        mouse.level = 15
        XCTAssertEqual(run([mouse]), [])
        // 充電回到門檻以上（多 2%）才會再通知
        mouse.level = 22
        XCTAssertEqual(run([mouse]), [])
        mouse.level = 23
        XCTAssertEqual(run([mouse]), [])
        mouse.level = 19
        XCTAssertEqual(run([mouse]), ["mouse"])
        // 門檻設為 0 表示不通知
        var silent = PeripheralAlerts()
        XCTAssertTrue(silent.evaluate([mouse]) { _ in 0 }.isEmpty)
    }
}
