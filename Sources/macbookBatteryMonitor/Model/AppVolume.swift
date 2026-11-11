import Foundation

/// 各 App 分開調音量（播放在 AppVolumeController）。
/// 只有調低或靜音的 App 才會被擷取、改音量再播放；維持 100% 的 App 完全不碰，不多耗電
enum AppVolume {
    struct Setting: Equatable {
        /// 0～1
        var volume: Double = 1
        var muted = false

        var gain: Float { muted ? 0 : Float(AppVolume.clamp(volume)) }
        /// 100% 且沒靜音：不用擷取
        var needsTap: Bool { muted || AppVolume.clamp(volume) < 0.995 }
    }

    static func clamp(_ volume: Double) -> Double { volume.isFinite ? min(max(volume, 0), 1) : 1 }

    /// 發出聲音的常常是 Helper 程序（例如瀏覽器的「Helper (Renderer)」），它的套件識別碼以 App 的識別碼開頭：
    /// 取最長的、在「.」邊界上相符的那個 App
    static func owner(ofProcessBundleID processID: String, apps: Set<String>) -> String? {
        guard !processID.isEmpty else { return nil }
        return apps.filter { processID == $0 || processID.hasPrefix($0 + ".") }.max { $0.count < $1.count }
    }

    // MARK: - 儲存

    /// 存成 [識別碼: [volume, muted]]；只存不是預設值的
    static func stored(_ settings: [String: Setting]) -> [String: [String: Any]] {
        settings.filter { $0.value.needsTap }.mapValues { ["volume": clamp($0.volume), "muted": $0.muted] }
    }

    /// 讀回時檢查型別與範圍；壞掉的項目略過
    static func settings(stored: [String: Any]) -> [String: Setting] {
        var result: [String: Setting] = [:]
        for (key, value) in stored {
            guard !key.isEmpty, key.count <= 255, let dict = value as? [String: Any] else { continue }
            let volume = (dict["volume"] as? Double).map(clamp) ?? 1
            let muted = dict["muted"] as? Bool ?? false
            let setting = Setting(volume: volume, muted: muted)
            if setting.needsTap { result[key] = setting }
        }
        return result
    }
}

// MARK: - 混音（音訊執行緒上跑：不配置記憶體、不上鎖）

extension AppVolume {
    /// 把擷取到的交錯 Float32 聲音乘上音量寫到輸出：輸出聲道比較少時取平均（例如藍牙通話時的單聲道），
    /// 比較多時重複最後一個聲道；音量每個取樣往目標靠近一點，避免突然變大小的爆音。
    /// 回傳更新後的音量與這段輸入的最大振幅（用來判斷是不是一直收到無聲資料）
    static func mix(input: UnsafePointer<Float>, inputChannels: Int, inputSamples: Int,
                    output: UnsafeMutablePointer<Float>, outputChannels: Int, outputSamples: Int,
                    gain current: Float, target: Float, ramp: Float) -> (gain: Float, peak: Float) {
        guard outputChannels > 0, outputSamples > 0 else { return (current, 0) }
        guard inputChannels > 0, inputSamples > 0 else {
            output.update(repeating: 0, count: outputSamples)
            return (current, 0)
        }
        let frames = min(inputSamples / inputChannels, outputSamples / outputChannels)
        var gain = current
        var peak: Float = 0
        for frame in 0..<frames {
            gain += (target - gain) * ramp
            let source = input + frame * inputChannels
            for channel in 0..<inputChannels { peak = max(peak, abs(source[channel])) }
            let destination = output + frame * outputChannels
            if outputChannels < inputChannels {
                var sum: Float = 0
                for channel in 0..<inputChannels { sum += source[channel] }
                let mono = sum / Float(inputChannels) * gain
                for channel in 0..<outputChannels { destination[channel] = mono }
            } else {
                for channel in 0..<outputChannels { destination[channel] = source[min(channel, inputChannels - 1)] * gain }
            }
        }
        let written = frames * outputChannels
        if written < outputSamples { (output + written).update(repeating: 0, count: outputSamples - written) }
        return (gain, peak)
    }

    /// 約 30 ms 從目前音量滑到目標音量的係數
    static func rampCoefficient(sampleRate: Double) -> Float {
        sampleRate > 0 ? Float(1 - exp(-1 / (sampleRate * 0.030))) : 1
    }
}
