import Foundation
import AVFAudio
import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.opentypeless.app", category: "audio")

/// 音频采集器（非实时模式）：录完整段音频并落盘 m4a。
///
/// 基于 HALAudioInput（HAL AudioUnit），能可靠采集任意指定输入设备。
/// 处理链：onBuffer → 软噪声门 → 写文件 + onLevel
/// - 软噪声门：三段式（大幅衰减 → 线性过渡 → 全通），避免语音开头被截断
/// - 音频电平：RMS → 归一化 0~1，用于菜单栏图标动画
final class AudioRecorder {
    enum AudioError: LocalizedError {
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .engineStartFailed(let message):
                return "Audio capture failed to start: \(message)"
            }
        }
    }

    private let input = HALAudioInput()
    private var isRunning = false

    /// 串行队列：保护 outputFile / pendingOutputURL / onLevel 等共享状态，
    /// 避免 buffer 回调线程与 start()/stop() 调用线程的数据竞争。
    private let stateQueue = DispatchQueue(label: "OpenTypeless.AudioRecorder.state")

    private var onLevel: ((Double) -> Void)?
    private var outputFile: AVAudioFile?

    /// 开始录音。
    /// - Parameters:
    ///   - inputDeviceID: 指定的输入设备（CoreAudio AudioDeviceID）。nil 用系统默认。
    ///   - recordToFile: 录音文件 URL（m4a），必须提供。
    ///   - onLevel: 音频电平 0~1，用于 UI 反馈。
    func start(
        inputDeviceID: AudioDeviceID?,
        recordToFile: URL,
        onLevel: @escaping (Double) -> Void
    ) throws {
        self.onLevel = onLevel

        // 准备 m4a 输出文件（用 HALAudioInput 的实际输出格式，在第一个 buffer 时确定）
        self.pendingOutputURL = recordToFile
        logger.info("Recording to file: \(recordToFile.lastPathComponent)")

        input.onBuffer = { [weak self] buffer in
            guard let self else { return }
            // 派到串行队列，保证与 stop() 的状态清空不交错
            self.stateQueue.async {
                self.handleBufferLocked(buffer)
            }
        }

        let deviceID = inputDeviceID ?? 0
        do {
            try input.start(deviceID: deviceID)
            isRunning = input.isRunning
            logger.info("Audio recorder started (device=\(deviceID))")
        } catch {
            throw AudioError.engineStartFailed(error.localizedDescription)
        }
    }

    /// 缓冲第一个 buffer 的格式来确定 m4a 写入参数（HALAudioInput 在 start 后才有 format）。
    private var pendingOutputURL: URL?

    /// 处理每个采集 buffer（必须在 stateQueue 上调用）。
    /// 建文件（首次）→ 降噪 → 写文件 + 电平。
    private func handleBufferLocked(_ buffer: AVAudioPCMBuffer) {
        // 首个 buffer：用实际格式创建输出文件
        if outputFile == nil, let url = pendingOutputURL {
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: buffer.format.sampleRate,
                AVNumberOfChannelsKey: buffer.format.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            do {
                outputFile = try AVAudioFile(forWriting: url, settings: outputSettings)
                pendingOutputURL = nil
            } catch {
                logger.error("Could not create output file: \(error.localizedDescription)")
                return
            }
        }

        applySoftNoiseGate(to: buffer)
        let level = AudioMeterCalculator.audioLevel(from: buffer)
        let handler = onLevel
        if let file = outputFile {
            try? file.write(from: buffer)
        }
        // 电平回调在队列外触发，避免阻塞串行队列
        if let handler {
            DispatchQueue.main.async { handler(level) }
        }
    }

    /// 停止录音并释放资源。
    func stop() {
        guard isRunning else { return }
        // 先同步停止采集，确保不再有新 buffer 回调
        input.stop()
        // 同步屏障：等串行队列上所有在途的 handleBuffer 执行完，再清空状态
        stateQueue.sync {
            onLevel = nil
            outputFile = nil
            pendingOutputURL = nil
        }
        isRunning = false
        logger.info("Audio recorder stopped")
    }

    var isRecording: Bool { isRunning }

    // MARK: - Processing Chain

    /// 软噪声门：参照 PowerMeetings applySoftNoiseGate。
    /// - magnitude < noiseFloor (0.012): 衰减到 18%
    /// - noiseFloor ≤ magnitude < speechFloor (0.05): 线性过渡 18% → 100%
    /// - magnitude ≥ speechFloor: 全通
    private func applySoftNoiseGate(to buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let noiseFloor: Float = 0.012
        let speechFloor: Float = 0.05

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let value = samples[frame]
                let magnitude = abs(value)
                if magnitude < noiseFloor {
                    samples[frame] = value * 0.18
                } else if magnitude < speechFloor {
                    let blend = (magnitude - noiseFloor) / (speechFloor - noiseFloor)
                    samples[frame] = value * (0.18 + 0.82 * blend)
                }
            }
        }
    }
}

// MARK: - Audio Meter Calculator (from PowerMeetings)

/// RMS 音频电平计算，归一化到 0~1。
enum AudioMeterCalculator {
    static func audioLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        var totalSquares = 0.0
        var sampleCount = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = Double(samples[frame])
                totalSquares += sample * sample
            }
            sampleCount += frameLength
        }

        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(totalSquares / Double(sampleCount))
        return normalizedMeterLevel(rms: rms)
    }

    static func normalizedMeterLevel(rms: Double) -> Double {
        guard rms.isFinite else { return 0 }
        return min(1, max(0.03, pow(rms * 12, 0.65)))
    }
}
