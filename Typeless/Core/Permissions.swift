import Cocoa
import Foundation
import ApplicationServices
import CoreGraphics
import AVFAudio
import Speech
import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.typeless.app", category: "permissions")

// MARK: - Audio Device Info

struct AudioDevice: Identifiable {
    let id: String
    let name: String
    let deviceID: AudioDeviceID
}

// MARK: - Permissions (Singleton)

@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published var accessibilityGranted = false
    @Published var inputMonitoringGranted = false
    @Published var microphoneGranted = false
    @Published var speechRecognitionGranted = false
    @Published var audioDevices: [AudioDevice] = []

    private var timer: Timer?

    private init() {
        refreshAll()
        // Poll for permission changes (user may grant in System Settings)
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAll()
            }
        }
    }

    func refreshAll() {
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = checkInputMonitoring()
        microphoneGranted = checkMicrophone()
        speechRecognitionGranted = checkSpeechRecognition()
        audioDevices = listAudioInputDevices()
    }

    // MARK: - Checkers

    private func checkInputMonitoring() -> Bool {
        CGPreflightListenEventAccess()
    }

    private func checkMicrophone() -> Bool {
        return AVAudioApplication.shared.recordPermission == .granted
    }

    private func checkSpeechRecognition() -> Bool {
        return SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    // MARK: - Requesters

    func requestAccessibility() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        if !accessibilityGranted {
            openAccessibilitySettings()
        }
    }

    func requestInputMonitoring() {
        inputMonitoringGranted = CGRequestListenEventAccess()
        if !inputMonitoringGranted {
            openInputMonitoringSettings()
        }
    }

    func requestMicrophone() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                self?.microphoneGranted = granted
                logger.info("Microphone permission: \(granted)")
            }
        }
    }

    func requestSpeechRecognition() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.speechRecognitionGranted = (status == .authorized)
                logger.info("Speech recognition permission: \(String(describing: status))")
            }
        }
    }

    // MARK: - Open System Settings

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Audio Devices

    private func listAudioInputDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        var devices: [AudioDevice] = []
        for id in deviceIDs {
            let isInput = deviceHasInputStreams(deviceID: id)
            guard isInput else { continue }
            let name = getPropertyString(deviceID: id, selector: kAudioObjectPropertyName) ?? "Unknown"
            devices.append(AudioDevice(id: "\(id)", name: name, deviceID: id))
        }
        return devices
    }

    private func deviceHasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return false }
        
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferList.deallocate() }
        var mutableSize = size
        let getStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &mutableSize, bufferList)
        guard getStatus == noErr else { return false }
        
        let list = bufferList.pointee
        return list.mNumberBuffers > 0
    }

    private func getPropertyBool(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private func getPropertyString(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfString: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfString)
        guard status == noErr else { return nil }
        return cfString?.takeRetainedValue() as String?
    }
}
