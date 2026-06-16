import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.opentypeless.app", category: "settings")

// MARK: - Configuration Models

struct LLMConfig: Codable, Equatable {
    var textProvider: String = "openai"
    var textApiKey: String = ""
    var textModel: String = "gpt-4o-mini"
    var textBaseUrl: String = "https://api.openai.com"

    var asrProvider: String = "same"
    var asrApiKey: String = ""
    var asrModel: String = "gpt-4o-mini"
    var asrBaseUrl: String = "https://api.openai.com"

    /// 当 true 时，ASR Model 复用 Text Model 的 provider / apiKey / baseUrl，只单独设 model。
    var asrProviderSameAsText: Bool = true
}

private let supportedASRProviders: Set<String> = ["same", "openai", "aliyun"]

// ASRConfig is defined in Core/ASREngine.swift (the canonical version).

struct ShortcutConfig: Codable, Equatable {
    var role: String = "A" // A, B, or C
    var keyCode: Int = 0
    var modifierFlags: Int = 0 // NSEvent.ModifierFlags raw value
}

struct ShortcutsConfig: Codable, Equatable {
    /// 默认快捷键：Option + 1/2/3（option rawValue = 524288，键码见 KeyCodes）。
    private static let optionModifier = Int(NSEvent.ModifierFlags.option.rawValue)
    private static let keyOne = 0x12, keyTwo = 0x13, keyThree = 0x14

    var a: ShortcutConfig = .init(role: "A", keyCode: keyOne, modifierFlags: optionModifier)
    var b: ShortcutConfig = .init(role: "B", keyCode: keyTwo, modifierFlags: optionModifier)
    var c: ShortcutConfig = .init(role: "C", keyCode: keyThree, modifierFlags: optionModifier)
}

// MARK: - AppSettings (Singleton, persisted via UserDefaults)

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var llm: LLMConfig {
        didSet { save(key: "llm", value: llm) }
    }

    @Published var asr: ASRConfig {
        didSet { save(key: "asr", value: asr) }
    }

    @Published var shortcuts: ShortcutsConfig {
        didSet { save(key: "shortcuts", value: shortcuts) }
    }

    @Published var targetLanguage: String {
        didSet { save(key: "targetLanguage", value: targetLanguage) }
    }

    @Published var audioInputDeviceID: String {
        didSet { UserDefaults.standard.set(audioInputDeviceID, forKey: "audioInputDeviceID") }
    }

    /// 录音时静音系统输出（避免扬声器声音被麦克风采到）。
    @Published var muteSystemAudioDuringRecording: Bool {
        didSet { UserDefaults.standard.set(muteSystemAudioDuringRecording, forKey: "muteSystemAudioDuringRecording") }
    }

    /// 交互声音（开始/停止录音时各播一声）。
    @Published var playInteractionSound: Bool {
        didSet { UserDefaults.standard.set(playInteractionSound, forKey: "playInteractionSound") }
    }

    // MARK: - Init

    private init() {
        var loadedLLM = Self.load(key: "llm") ?? LLMConfig()
        loadedLLM.asrProvider = loadedLLM.asrProvider.lowercased()
        if supportedASRProviders.contains(loadedLLM.asrProvider) == false {
            loadedLLM.asrProvider = "openai"
            loadedLLM.asrProviderSameAsText = false
        }
        if loadedLLM.asrProvider == "aliyun" {
            loadedLLM.asrProviderSameAsText = false
            if loadedLLM.asrModel.isEmpty || loadedLLM.asrModel == "gpt-4o-mini" {
                loadedLLM.asrModel = "qwen3-asr-flash"
            }
            if loadedLLM.asrBaseUrl.isEmpty || loadedLLM.asrBaseUrl == "https://api.openai.com" {
                loadedLLM.asrBaseUrl = "https://dashscope.aliyuncs.com/compatible-mode/v1"
            }
        }
        self.llm = loadedLLM
        self.asr = Self.load(key: "asr") ?? ASRConfig()
        self.shortcuts = Self.load(key: "shortcuts") ?? ShortcutsConfig()
        self.targetLanguage = UserDefaults.standard.string(forKey: "targetLanguage") ?? "English"
        self.audioInputDeviceID = UserDefaults.standard.string(forKey: "audioInputDeviceID") ?? ""
        // 注意：上面 audioInputDeviceID 的 didSet 不会触发（init 直接赋值），这里手动存一次以保证键名一致
        self.muteSystemAudioDuringRecording = UserDefaults.standard.object(forKey: "muteSystemAudioDuringRecording") as? Bool ?? false
        self.playInteractionSound = UserDefaults.standard.object(forKey: "playInteractionSound") as? Bool ?? true
        logger.info("Settings loaded")
    }

    // MARK: - Persistence

    private func save<T: Codable>(key: String, value: T) {
        do {
            let data = try JSONEncoder().encode(value)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            logger.error("Failed to save \(key): \(error.localizedDescription)")
        }
    }

    private static func load<T: Codable>(key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
