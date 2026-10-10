import Foundation
import Observation

/// 管理員權限只用來執行系統內建的 powermetrics，不安裝常駐服務。
@MainActor @Observable
final class AdminCPUSampler {
    private(set) var status = "尚未啟用"
    private(set) var authorizing = false
    @ObservationIgnored var authorizationChanged: ((Bool) -> Void)?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var lease: URL?
    @ObservationIgnored private var output: FileHandle?
    @ObservationIgnored private var outputPath: String?
    @ObservationIgnored private var parser = CPUPowerStream()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var failed = false
    @ObservationIgnored private var started: TimeInterval = 0
    @ObservationIgnored private var reading: (Double, TimeInterval)?

    func update(active: Bool, enabled: Bool) {
        guard active && enabled else {
            stop()
            if !enabled { failed = false; status = "尚未啟用" }
            return
        }
        if let lease {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: lease.path)
        }
        guard !failed else { return }
        if let output {
            do {
                guard let outputPath,
                      let metadata = try? FileManager.default.attributesOfItem(atPath: outputPath),
                      let modified = metadata[.modificationDate] as? Date,
                      (0...3).contains(Date().timeIntervalSince(modified)) else {
                    fail("CPU 資料已逾時，請關閉再開啟此選項以重試。")
                    return
                }
                let bytes = try output.readToEnd() ?? Data()
                if let watts = parser.append(String(decoding: bytes, as: UTF8.self)) {
                    reading = (watts, ProcessInfo.processInfo.systemUptime)
                    status = "每秒取樣中"
                }
                if ProcessInfo.processInfo.systemUptime - (reading?.1 ?? started) > 5 {
                    fail("取樣已停止，請關閉再開啟此選項以重試。")
                }
            } catch { fail("無法讀取 CPU 功耗，請重新啟用。") }
        } else if process == nil { launch() }
    }

    var watts: Double? {
        guard let reading, ProcessInfo.processInfo.systemUptime - reading.1 <= 3 else { return nil }
        return reading.0
    }

    func stop() {
        generation = UUID()
        if let lease { try? FileManager.default.removeItem(at: lease) }
        lease = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        try? output?.close()
        output = nil
        outputPath = nil
        parser = CPUPowerStream()
        reading = nil
        if authorizing { authorizing = false; authorizationChanged?(false) }
        if !failed { status = "主面板開啟時取樣" }
    }

    private func fail(_ message: String) {
        stop()
        failed = true
        status = message
    }

    private func launch() {
        let token = UUID()
        generation = token
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("cpu-lease-\(UUID().uuidString)")
        do { try Data().write(to: marker, options: .atomic) }
        catch { fail("無法建立取樣工作。 "); return }
        lease = marker
        let pid = ProcessInfo.processInfo.processIdentifier
        // Root 只在自行建立、不可被一般使用者修改的目錄寫入資料。
        // 使用者提供的 lease 僅讀取；不從檔案接受指令或 PID。
        let script = """
        /bin/test -f \(Self.quote(marker.path)) || exit 1
        dir=$(/usr/bin/mktemp -d /private/tmp/com.kuan.batterymonitor.cpu.XXXXXXXX) || exit 1
        /bin/chmod 755 "$dir" && /usr/bin/touch "$dir/output" && /bin/chmod 644 "$dir/output" || {
          /bin/rm -rf "$dir"
          exit 1
        }
        (
          child=''
          trap '[ -z "$child" ] || /bin/kill "$child" 2>/dev/null; [ -z "$child" ] || wait "$child" 2>/dev/null; /bin/rm -rf "$dir"' EXIT
          trap 'exit' TERM INT HUP
          /usr/bin/powermetrics --samplers cpu_power -i 1000 -n 1800 -b 1 > "$dir/output" 2> "$dir/error" &
          child=$!
          end=$(( $(/bin/date +%s) + 1800 ))
          while /bin/kill -0 "$child" 2>/dev/null && /bin/kill -0 \(pid) 2>/dev/null; do
            stamp=$(/usr/bin/stat -f %m \(Self.quote(marker.path)) 2>/dev/null) || break
            now=$(/bin/date +%s)
            [ "$now" -lt "$end" ] && [ $(( now - stamp )) -lt 5 ] || break
            /bin/sleep 1
          done
        ) </dev/null >/dev/null 2>&1 &
        /usr/bin/printf '%s' "$dir"
        """
        let appleScript = "do shell script \"\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n"))\" with administrator privileges"
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", appleScript]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] task in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let succeeded = task.terminationStatus == 0
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.process = nil
                self.authorizing = false
                self.authorizationChanged?(false)
                guard succeeded, path.hasPrefix("/private/tmp/com.kuan.batterymonitor.cpu."),
                      !path.dropFirst("/private/tmp/".count).contains("/"),
                      let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
                      (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o755,
                      let handle = FileHandle(forReadingAtPath: path + "/output") else {
                    self.fail("授權取消或取樣失敗，請關閉再開啟此選項以重試。")
                    return
                }
                self.output = handle
                self.outputPath = path + "/output"
                self.started = ProcessInfo.processInfo.systemUptime
                self.status = "等待第一筆 CPU 資料"
            }
        }
        process = task
        authorizing = true
        status = "等待系統管理員授權"
        authorizationChanged?(true)
        do { try task.run() }
        catch { fail("無法啟動系統授權。") }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
