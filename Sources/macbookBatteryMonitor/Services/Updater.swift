import AppKit
import CryptoKit
import Foundation
import Observation

/// 一鍵更新：從 GitHub Releases 下載同一個版本別的新版，驗證後換掉目前的 App 並重新開啟
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(ReleaseInfo)
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastChecked: Date?

    static let releasesAPI = URL(string: "https://api.github.com/repos/sgeric910601/macbookBatteryMonitor/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/sgeric910601/macbookBatteryMonitor/releases/latest")!
    /// 自動檢查的間隔
    static let checkInterval: TimeInterval = 24 * 3600
    private static let lastCheckKey = "lastUpdateCheck"

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    var available: ReleaseInfo? {
        switch state {
        case .available(let release), .downloading(let release): return release
        default: return nil
        }
    }

    /// 只有正式打包的 App 才能安裝（開發用的執行檔沒有 .app 可以換）
    var canInstall: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier == "com.kuan.batterymonitor"
    }

    init() {
        lastChecked = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
    }

    /// 自動檢查：距離上次超過一天才查；查不到不顯示錯誤
    func checkIfDue() {
        guard state == .idle || state == .upToDate else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.checkInterval { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        var request = URLRequest(url: Self.releasesAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("macbookBatteryMonitor/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckKey)
            guard let release = UpdateLogic.release(json: data, edition: AppEdition.current.rawValue),
                  let current = UpdateLogic.version(currentVersion) else {
                state = userInitiated ? .failed("找不到這個版本別的下載檔") : .idle
                return
            }
            state = UpdateLogic.isNewer(release.version, than: current) ? .available(release) : .upToDate
        } catch {
            state = userInitiated ? .failed("無法連線到 GitHub，請稍後再試") : .idle
        }
    }

    /// 下載、驗證、安裝；成功時 App 會結束並由安裝程序重新開啟新版
    func install() async {
        guard let release = available, canInstall else { return }
        let target = Bundle.main.bundleURL
        let folder = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path), FileManager.default.isWritableFile(atPath: target.path) else {
            state = .failed("App 所在位置沒有寫入權限，請到 GitHub 手動下載")
            return
        }
        state = .downloading(release)
        do {
            let staged = try await Self.download(release)
            state = .installing
            try Self.launchInstaller(staged: staged, target: target)
            // 讓畫面先顯示「安裝中」再結束
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApp.terminate(nil)
        } catch let error as UpdateError {
            state = .failed(error.message)
        } catch {
            state = .failed("下載失敗：\(error.localizedDescription)")
        }
    }

    struct UpdateError: Error { let message: String }

    /// 下載 zip、比對 SHA-256、解壓並驗證內容，回傳準備好的新版 App 位置
    nonisolated private static func download(_ release: ReleaseInfo) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var request = URLRequest(url: release.assetURL, timeoutInterval: 120)
        request.setValue("macbookBatteryMonitor", forHTTPHeaderField: "User-Agent")
        let (temp, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let final = response.url, UpdateLogic.isTrusted(final) else {
            throw UpdateError(message: "下載失敗：伺服器回應異常")
        }
        let zip = work.appendingPathComponent(release.assetName)
        try FileManager.default.moveItem(at: temp, to: zip)
        let data = try Data(contentsOf: zip)
        guard data.count > 0, data.count < 100_000_000 else { throw UpdateError(message: "下載的檔案大小異常") }

        // 有校驗檔就一定要對得上
        if let checksumURL = release.checksumURL {
            let (sums, _) = try await URLSession.shared.data(from: checksumURL)
            guard let expected = UpdateLogic.checksum(in: String(decoding: sums, as: UTF8.self), for: release.assetName) else {
                throw UpdateError(message: "校驗檔裡找不到這個下載檔")
            }
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw UpdateError(message: "下載的檔案校驗不符，已取消更新") }
        }

        let unpacked = work.appendingPathComponent("unpacked")
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) == 0 else { throw UpdateError(message: "解壓縮失敗") }
        let app = unpacked.appendingPathComponent("macbookBatteryMonitor.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.kuan.batterymonitor",
              info["MBMEdition"] as? String == AppEdition.current.rawValue,
              (info["CFBundleShortVersionString"] as? String).flatMap(UpdateLogic.version) == release.version else {
            throw UpdateError(message: "下載的 App 與目前的版本別或版本號不符")
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            throw UpdateError(message: "新版 App 的簽章驗證失敗")
        }
        return app
    }

    /// 寫一個小腳本：等這個 App 結束後換上新版（換不過去就放回原本的版本）並重新開啟
    nonisolated private static func launchInstaller(staged: URL, target: URL) throws {
        let script = staged.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("install.sh")
        try """
        #!/bin/sh
        pid="$1"; target="$2"; staged="$3"
        i=0
        while kill -0 "$pid" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
        backup="${target%.app}.previous.app"
        rm -rf "$backup"
        if mv "$target" "$backup" && mv "$staged" "$target"; then
          rm -rf "$backup"
        elif [ ! -d "$target" ] && [ -d "$backup" ]; then
          mv "$backup" "$target"
        fi
        xattr -dr com.apple.quarantine "$target" 2>/dev/null
        open "$target"
        rm -rf "$(dirname "$0")"
        """.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), target.path, staged.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// 開發用快照：直接設定狀態，檢查各狀態的版面
    func loadPreview(_ state: State) { self.state = state }

    nonisolated private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
