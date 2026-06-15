import Foundation
import os.log

private let logger = Logger(subsystem: "com.typeless.app", category: "settings")

// MARK: - Configuration Models

struct LLMConfig: Codable, Equatable {
    var textProvider: String = "openai"
    var textApiKey: String = ""
    var textModel: String = "gpt-4o-mini"
    var textBaseUrl: String = "https://api.openai.com"

    var visionProvider: String = "openai"
    var visionApiKey: String = ""
    var visionModel: String = "gpt-4o"
    var visionBaseUrl: String = "https://api.openai.com"
}

// ASRConfig is defined in Core/ASREngine.swift (the canonical version).

struct ShortcutConfig: Codable, Equatable {
    var role: String = "A" // A, B, or C
    var keyCode: Int = 0
    var modifierFlags: Int = 0 // NSEvent.ModifierFlags raw value
}

struct ShortcutsConfig: Codable, Equatable {
    var a: ShortcutConfig = .init(role: "A", keyCode: 0, modifierFlags: 0)
    var b: ShortcutConfig = .init(role: "B", keyCode: 0, modifierFlags: 0)
    var c: ShortcutConfig = .init(role: "C", keyCode: 0, modifierFlags: 0)
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
        didSet { save(key: "audioInputDeviceID", value: audioInputDeviceID) }
    }

    // MARK: - Init

    private init() {
        self.llm = Self.load(key: "llm") ?? LLMConfig()
        self.asr = Self.load(key: "asr") ?? ASRConfig()
        self.shortcuts = Self.load(key: "shortcuts") ?? ShortcutsConfig()
        self.targetLanguage = UserDefaults.standard.string(forKey: "targetLanguage") ?? "English"
        self.audioInputDeviceID = UserDefaults.standard.string(forKey: "audioInputDeviceID") ?? ""
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
