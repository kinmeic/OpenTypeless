import Foundation
import AVFAudio
import Speech

// MARK: - ASR Protocol

/// 语音转文字引擎协议。
/// 两种实现：SystemSpeechASR（系统内置）、RemoteASR（大模型 WebSocket 流式）。
protocol ASREngine: AnyObject {
    /// 开始一次识别会话。
    func start() throws

    /// 喂入音频 buffer（流式）。
    func feed(_ buffer: AVAudioPCMBuffer)

    /// 停止并返回最终转写结果。
    func finalize() async throws -> String

    /// 是否正在识别。
    var isRunning: Bool { get }
}

// MARK: - ASR Result

struct ASRResult {
    let text: String
    let languageID: String?
    let isFinal: Bool
}

// MARK: - ASR Config

enum ASREngineType: String, Codable, CaseIterable {
    case systemSpeech = "system"
    case remote = "remote"
}

struct ASRConfig: Codable, Equatable {
    var engine: ASREngineType = .systemSpeech

    /// 系统 STT 多语言并行识别的语言列表。
    var languageIDs: [String] = ["zh-CN", "en-US"]

    // 远程 ASR 配置（仅 engine == .remote 时有效）
    var remoteProvider: String = "aliyun"
    var remoteEndpoint: String = "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
    var remoteApiKey: String = ""
    var remoteModel: String = "fun-asr-realtime"
    var remoteSampleRate: Int = 16_000

    /// 系统 STT 是否可用（权限 + recognizer 存在）。
    var systemSpeechAvailable: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// 远程 ASR 是否已配置。
    var remoteConfigured: Bool {
        !remoteApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
