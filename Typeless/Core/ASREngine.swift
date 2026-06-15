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

    /// 系统 STT 多语言并行识别的语言列表。
    var languageIDs: [String] = ["zh-CN", "en-US"]

    /// 系统 STT 是否可用（权限 + recognizer 存在）。
    var systemSpeechAvailable: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }
}
