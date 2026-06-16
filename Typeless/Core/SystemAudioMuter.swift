import Foundation
import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.opentypeless.app", category: "audio-muter")

/// 系统输出静音器：录音期间把系统默认输出设备静音，停止后恢复原状态。
///
/// 通过 Core Audio 的 kAudioDevicePropertyMute（scope output, element 0）操作。
final class SystemAudioMuter {
    private var wasMuted: Bool?
    private var deviceID: AudioDeviceID = 0

    /// 静音系统默认输出设备，记录原状态以便恢复。
    func mute() {
        guard deviceID == 0 else { return }  // 已静音，避免覆盖原状态
        deviceID = defaultOutputDeviceID() ?? 0
        guard deviceID != 0 else {
            logger.warning("No default output device to mute")
            return
        }
        wasMuted = getMute(deviceID)
        if wasMuted != true {
            setMute(deviceID, muted: true)
            logger.info("Muted system output (device \(self.deviceID), was muted=\(self.wasMuted ?? false))")
        }
    }

    /// 恢复系统输出到原状态。
    func restore() {
        guard deviceID != 0 else { return }
        if let wasMuted, wasMuted == false {
            setMute(deviceID, muted: false)
            logger.info("Restored system output (device \(self.deviceID))")
        }
        deviceID = 0
        wasMuted = nil
    }

    // MARK: - Core Audio Helpers

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var propSize: UInt32 = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &deviceID) == noErr else {
            return nil
        }
        return deviceID
    }

    private func getMute(_ deviceID: AudioDeviceID) -> Bool? {
        var muted: UInt32 = 0
        var propSize: UInt32 = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propSize, &muted) == noErr else {
            return nil
        }
        return muted != 0
    }

    private func setMute(_ deviceID: AudioDeviceID, muted: Bool) {
        var value: UInt32 = muted ? 1 : 0
        let propSize: UInt32 = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0
        )
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, propSize, &value)
        if status != noErr {
            logger.error("Failed to set mute \(muted) on device \(deviceID): \(status)")
        }
    }
}
