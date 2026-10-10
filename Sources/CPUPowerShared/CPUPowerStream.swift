import Foundation

/// powermetrics 的文字串流可能在任意位元組位置分段。
public struct CPUPowerStream {
    public init() {}
    private var pending = ""
    public mutating func append(_ text: String) -> Double? {
        pending += text
        let lines = pending.components(separatedBy: "\n")
        pending = String(lines.last?.suffix(4096) ?? "")
        var latest: Double?
        for line in lines.dropLast() {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count == 4, parts[0] == "CPU", parts[1] == "Power:",
                  parts[3] == "mW", let mw = Double(parts[2]),
                  mw.isFinite, mw >= 0, mw < 500_000 else { continue }
            latest = mw / 1000
        }
        return latest
    }
}
