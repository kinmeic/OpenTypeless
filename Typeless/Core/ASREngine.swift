import Foundation
import AVFAudio
import Speech

// MARK: - ASR Protocol

/// 语音转文字引擎协议（非实时 batch 模式）。
/// 两种实现：SystemSpeechASR（系统内置）、LLMASR（LLM 音频转写 API，如智谱 GLM-ASR）。
/// 调用方式统一为：录完整段音频落盘后，调 `transcribeFile(_:)` 一次性转写。
protocol ASREngine: AnyObject {
    /// 对整段已落盘的音频文件做一次性识别。
    /// - Parameter url: 录音文件 URL（m4a/wav 等）。
    /// - Returns: 整段转写文字。
    func transcribeFile(_ url: URL) async throws -> String
}

// MARK: - ASR Config

enum ASREngineType: String, Codable, CaseIterable {
    case systemSpeech = "system"
    case llm = "llm"
}

struct ASRConfig: Codable, Equatable {
    var engine: ASREngineType = .systemSpeech

    var recognitionLanguageID: String = "zh-CN"

    /// 系统 STT 是否可用（权限 + recognizer 存在）。
    var systemSpeechAvailable: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    static let supportedSystemLanguages: [ASRLanguage] = [
        .init(id: "zh-CN", name: "中文（普通话）"),
        .init(id: "en-US", name: "English (US)"),
        .init(id: "ja-JP", name: "日本語"),
        .init(id: "ko-KR", name: "한국어"),
        .init(id: "fr-FR", name: "Français"),
        .init(id: "de-DE", name: "Deutsch"),
        .init(id: "es-ES", name: "Español")
    ]

    init(
        engine: ASREngineType = .systemSpeech,
        recognitionLanguageID: String = "zh-CN"
    ) {
        self.engine = engine
        self.recognitionLanguageID = recognitionLanguageID
    }

    private enum CodingKeys: String, CodingKey {
        case engine
        case recognitionLanguageID
        case languageIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engine = try container.decodeIfPresent(ASREngineType.self, forKey: .engine) ?? .systemSpeech
        let legacyLanguageIDs = try container.decodeIfPresent([String].self, forKey: .languageIDs)
        recognitionLanguageID = try container.decodeIfPresent(String.self, forKey: .recognitionLanguageID)
            ?? legacyLanguageIDs?.first
            ?? "zh-CN"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(engine, forKey: .engine)
        try container.encode(recognitionLanguageID, forKey: .recognitionLanguageID)
    }
}

struct ASRLanguage: Identifiable, Hashable {
    let id: String
    let name: String
}
