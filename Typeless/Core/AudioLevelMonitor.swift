import Foundation
import AVFAudio
import CoreAudio
import Combine
import os.log

private let logger = Logger(subsystem: "com.typeless.app", category: "audio-level")

/// 轻量电平监测器：只采集音频电平用于 UI 反馈，不录音、不落盘。
///
/// 基于 HALAudioInput（HAL AudioUnit），能可靠采集任意指定输入设备。
/// 与 AudioRecorder 独立，用于设置页的"输入设备收音预览"。
@MainActor
final class AudioLevelMonitor: ObservableObject {
    /// 当前电平 0~1。
    @Published private(set) var level: Double = 0

    /// 是否正在监测（单一真源，View 应绑定它判断按钮状态）。
    @Published private(set) var isRunning: Bool = false

    private let input = HALAudioInput()

    /// 开始监测指定输入设备的电平。
    /// - Parameter deviceID: 设备 ID。0 表示系统默认。
    /// - Returns: 是否成功启动。
    @discardableResult
    func start(deviceID: AudioDeviceID = 0) -> Bool {
        if isRunning {
            stop()
        }

        input.onBuffer = { [weak self] buffer in
            let computed = AudioMeterCalculator.audioLevel(from: buffer)
            Task { @MainActor in
                self?.level = computed
            }
        }

        do {
            try input.start(deviceID: deviceID)
            isRunning = input.isRunning
            logger.info("Level monitor started (device=\(deviceID))")
            return isRunning
        } catch {
            logger.error("Level monitor failed to start: \(error.localizedDescription)")
            level = 0
            isRunning = false
            return false
        }
    }

    /// 停止监测。
    func stop() {
        guard isRunning else { return }
        input.stop()
        isRunning = false
        level = 0
        logger.info("Level monitor stopped")
    }
}
