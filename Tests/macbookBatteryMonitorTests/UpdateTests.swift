import Foundation

final class UpdateTests {
    func testVersionParsingAndComparison() {
        XCTAssertEqual(UpdateLogic.version("v1.4.1"), [1, 4, 1])
        XCTAssertEqual(UpdateLogic.version("1.10.0"), [1, 10, 0])
        XCTAssertNil(UpdateLogic.version("v1.4.1-beta"))
        XCTAssertNil(UpdateLogic.version(""))
        XCTAssertTrue(UpdateLogic.isNewer([1, 4, 2], than: [1, 4, 1]))
        XCTAssertTrue(UpdateLogic.isNewer([1, 10, 0], than: [1, 9, 9]))
        XCTAssertTrue(!UpdateLogic.isNewer([1, 4], than: [1, 4, 0]))
        XCTAssertTrue(!UpdateLogic.isNewer([1, 4, 0], than: [1, 4, 1]))
        XCTAssertTrue(UpdateLogic.isNewer([2], than: [1, 99, 99]))
    }

    func testReleaseParsingPicksEditionAndChecksum() {
        let json = """
        {"tag_name":"v1.5.0","html_url":"https://github.com/sgeric910601/macbookBatteryMonitor/releases/tag/v1.5.0",
         "draft":false,"prerelease":false,"assets":[
          {"name":"macbookBatteryMonitor-v1.5.0-battery-macOS-arm64.zip","size":100,
           "browser_download_url":"https://github.com/sgeric910601/macbookBatteryMonitor/releases/download/v1.5.0/macbookBatteryMonitor-v1.5.0-battery-macOS-arm64.zip"},
          {"name":"macbookBatteryMonitor-v1.5.0-status-macOS-arm64.zip","size":200,
           "browser_download_url":"https://github.com/sgeric910601/macbookBatteryMonitor/releases/download/v1.5.0/macbookBatteryMonitor-v1.5.0-status-macOS-arm64.zip"},
          {"name":"SHA256SUMS.txt","size":10,
           "browser_download_url":"https://github.com/sgeric910601/macbookBatteryMonitor/releases/download/v1.5.0/SHA256SUMS.txt"}]}
        """
        let status = UpdateLogic.release(json: Data(json.utf8), edition: "status")
        XCTAssertEqual(status?.version, [1, 5, 0])
        XCTAssertEqual(status?.assetSize, 200)
        XCTAssertEqual(status?.assetName, "macbookBatteryMonitor-v1.5.0-status-macOS-arm64.zip")
        XCTAssertTrue(status?.checksumURL != nil)
        XCTAssertEqual(UpdateLogic.release(json: Data(json.utf8), edition: "battery")?.assetSize, 100)
        // 舊版 Release 沒有這個版本別的 zip、預覽版、或下載網址不是 GitHub，都不更新
        XCTAssertNil(UpdateLogic.release(json: Data(json.utf8), edition: "full"))
        XCTAssertNil(UpdateLogic.release(json: Data(json.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true").utf8), edition: "status"))
        XCTAssertNil(UpdateLogic.release(json: Data(json.replacingOccurrences(of: "https://github.com/sgeric910601/macbookBatteryMonitor/releases/download/v1.5.0/macbookBatteryMonitor-v1.5.0-status", with: "https://evil.example.com/x").utf8), edition: "status"))
        XCTAssertTrue(UpdateLogic.isTrusted(URL(string: "https://objects.githubusercontent.com/a")!))
        XCTAssertTrue(!UpdateLogic.isTrusted(URL(string: "http://github.com/a")!))
        XCTAssertTrue(!UpdateLogic.isTrusted(URL(string: "https://github.com.evil.com/a")!))
    }

    func testChecksumFileParsing() {
        let hash = String(repeating: "a1", count: 32)
        let text = "\(hash)  macbookBatteryMonitor-v1.5.0-status-macOS-arm64.zip\n\(String(repeating: "b2", count: 32))  other.zip\n"
        XCTAssertEqual(UpdateLogic.checksum(in: text, for: "macbookBatteryMonitor-v1.5.0-status-macOS-arm64.zip"), hash)
        XCTAssertNil(UpdateLogic.checksum(in: text, for: "missing.zip"))
        XCTAssertNil(UpdateLogic.checksum(in: "zzzz  file.zip", for: "file.zip"))
    }
}
