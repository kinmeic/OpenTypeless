import Foundation
import AVFAudio
import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.typeless.app", category: "audio")

/// 音频采集器：参照 PowerMeetings NoiseSuppressingMicrophoneRecorder。
///
/// 处理链：inputNode → highPass(85Hz) → 软噪声门 → tap → onBuffer/onLevel
/// - 高通滤波：滤除空调/风扇等低频环境噪声
/// - 软噪声门：三段式（大幅衰减 → 线性过渡 → 全通），避免语音开头被截断
/// - 音频电平：RMS → 归一化 0~1，用于菜单栏图标动画
final class AudioRecorder {
    enum AudioError: LocalizedError {
        case noInputFormat
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInputFormat:
                return "No microphone input format was available."
            case .engineStartFailed(let message):
                return "Audio engine failed to start: \(message)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let highPass = AVAudioUnitEQ(numberOfBands: 1)
    private var isRunning = false

    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var onLevel: ((Double) -> Void)?

    /// 开始录音。
    /// - Parameters:
    ///   - inputDeviceID: 指定的输入设备（CoreAudio AudioDeviceID）。nil 用系统默认。
    ///   - onBuffer: 每个音频 buffer 回调（喂给 ASR）。
    ///   - onLevel: 音频电平 0~1，用于 UI 反馈。
    func start(
        inputDeviceID: AudioDeviceID?,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping (Double) -> Void
    ) throws {
        configureProcessingChain()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioError.noInputFormat
        }

        engine.attach(highPass)
        engine.connect(inputNode, to: highPass, format: inputFormat)
        engine.connect(highPass, to: engine.mainMixerNode, format: inputFormat)
        // 静音输出，避免扬声器回声
        engine.mainMixerNode.outputVolume = 0

        self.onBuffer = onBuffer
        self.onLevel = onLevel

        highPass.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.applySoftNoiseGate(to: buffer)
            let level = AudioMeterCalculator.audioLevel(from: buffer)
            self.onLevel?(level)
            self.onBuffer?(buffer)
        }

        // 选择指定输入设备
        if let deviceID = inputDeviceID, deviceID != 0 {
            setInputDevice(deviceID)
        }

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
            logger.info("Audio recorder started (sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount))")
        } catch {
            highPass.removeTap(onBus: 0)
            throw AudioError.engineStartFailed(error.localizedDescription)
        }
    }

    /// 停止录音并释放资源。
    func stop() {
        guard isRunning else { return }
        highPass.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        isRunning = false
        onBuffer = nil
        onLevel = nil
        logger.info("Audio recorder stopped")
    }

    var isRecording: Bool { isRunning }

    // MARK: - Processing Chain

    private func configureProcessingChain() {
        guard let band = highPass.bands.first else { return }
        band.filterType = .highPass
        band.frequency = 85  // 滤除低频环境噪声
        band.bypass = false
    }

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

    // MARK: - Device Selection

    /// 设置 AVAudioEngine 的输入设备。
    /// 注意：AVAudioEngine 默认用系统当前 input device。要指定设备需通过 CoreAudio 设置
    /// AudioDeviceID 到 inputNode 的底层 AudioUnit 的 kAudioOutputUnitProperty_CurrentDevice 属性。
    /// 通过 AUGraph / AudioComponentDescription 获取 AU。
    private func setInputDevice(_ deviceID: AudioDeviceID) {
        // AVAudioInputNode 没有公开的 audioUnit 访问器；通过 AudioUnit 的 property 访问。
        // 取出 inputNode 的底层 AudioUnit（通过 AUGraph 或 kAudioUnitProperty_CurrentDevice）。
        // 这里使用与 PowerMeetings AudioDeviceManager 一致的做法：依赖系统默认设备，
        // 由用户在系统设置里选择输入源；App 内的设备选择通过设置系统默认设备实现。
        // （完整实现见设备选择增强阶段）
        logger.warning("Custom device selection requires system default device change; using current default (device \(deviceID) requested)")
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
