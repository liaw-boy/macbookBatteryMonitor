import Foundation

/// GitHub Releases 上最新版本、對應這個版本別（電池版／系統監控版）的下載資訊
struct ReleaseInfo: Equatable {
    var tag: String
    var version: [Int]
    var pageURL: URL
    var assetName: String
    var assetURL: URL
    var assetSize: Int
    /// Release 附的 SHA256SUMS.txt（加入一鍵更新之後的 Release 才有）
    var checksumURL: URL?

    var versionText: String { version.map(String.init).joined(separator: ".") }
}

enum UpdateLogic {
    static let checksumFile = "SHA256SUMS.txt"

    /// "v1.4.1"、"1.4.1" → [1, 4, 1]；有不是數字的部分就回傳 nil
    static func version(_ text: String) -> [Int]? {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.map { $0! }
    }

    /// 逐段比較，缺的段當 0（1.4 == 1.4.0）
    static func isNewer(_ candidate: [Int], than current: [Int]) -> Bool {
        for i in 0..<max(candidate.count, current.count) {
            let a = i < candidate.count ? candidate[i] : 0
            let b = i < current.count ? current[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    static func assetName(tag: String, edition: String) -> String {
        "macbookBatteryMonitor-\(tag)-\(edition)-macOS-arm64.zip"
    }

    /// 只從 GitHub 的網址下載（下載連結會轉址到 githubusercontent.com）
    static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host == "api.github.com" || host.hasSuffix(".githubusercontent.com")
    }

    /// 解析 GET /repos/{owner}/{repo}/releases/latest 的回應；找不到這個版本別的 zip 就回傳 nil
    static func release(json: Data, edition: String) -> ReleaseInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let tag = root["tag_name"] as? String, let version = version(tag),
              root["draft"] as? Bool != true, root["prerelease"] as? Bool != true,
              let page = (root["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = root["assets"] as? [[String: Any]] else { return nil }
        func asset(_ name: String) -> (url: URL, size: Int)? {
            guard let item = assets.first(where: { $0["name"] as? String == name }),
                  let url = (item["browser_download_url"] as? String).flatMap(URL.init(string:)), isTrusted(url) else { return nil }
            return (url, item["size"] as? Int ?? 0)
        }
        let name = assetName(tag: tag, edition: edition)
        guard let zip = asset(name) else { return nil }
        return ReleaseInfo(tag: tag, version: version, pageURL: page, assetName: name, assetURL: zip.url,
                           assetSize: zip.size, checksumURL: asset(checksumFile)?.url)
    }

    /// SHA256SUMS.txt 每行「<64 位十六進位>  <檔名>」
    static func checksum(in text: String, for name: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == name else { continue }
            let hash = parts[0].lowercased()
            if hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) { return hash }
        }
        return nil
    }
}
