import Foundation
import CoreAudio
import AudioUnit
import os.log

private let logger = Logger(subsystem: "com.typeless.app", category: "audio-device")

/// 音频输入设备管理：枚举系统音频输入设备，并把指定设备设置到 AVAudioEngine。
///
/// 注意：AVAudioEngine 默认用系统当前输入设备。要指定设备，需通过 CoreAudio 把
/// AudioDeviceID 写到 inputNode 底层 AudioUnit 的 kAudioOutputUnitProperty_CurrentDevice。
final class AudioDeviceManager {

    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
    }

    /// 枚举所有输入设备（有 input channel 的设备）。
    static func inputDevices() -> [Device] {
        var devices: [Device] = []

        var propSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize) == noErr else {
            return devices
        }

        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &deviceIDs) == noErr else {
            return devices
        }

        for deviceID in deviceIDs {
            if isInputDevice(deviceID), let name = deviceName(deviceID) {
                devices.append(Device(id: deviceID, name: name))
            }
        }
        return devices
    }

    /// 取系统当前默认输入设备。
    static func defaultInputDevice() -> Device? {
        var deviceID: AudioDeviceID = 0
        var propSize: UInt32 = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &deviceID) == noErr else {
            return nil
        }
        guard let name = deviceName(deviceID) else { return nil }
        return Device(id: deviceID, name: name)
    }

    // MARK: - Helpers

    private static func isInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: 0
        )
        var propSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propSize) == noErr else { return false }
        guard propSize > 0 else { return false }

        guard let bufferListPtr = malloc(Int(propSize)) else { return false }
        defer { free(bufferListPtr) }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propSize, bufferListPtr) == noErr else { return false }

        // 用 UnsafeMutableAudioBufferListPointer 安全遍历可变长 buffer list
        let totalChannels = UnsafeMutableAudioBufferListPointer(bufferListPtr.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
        return totalChannels > 0
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var name: CFString = "" as CFString
        var propSize: UInt32 = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propSize, &name)
        guard status == noErr else { return nil }
        return name as String
    }
}
