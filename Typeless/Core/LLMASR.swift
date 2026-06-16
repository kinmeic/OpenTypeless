import Foundation
import os.log

private let logger = Logger(subsystem: "com.opentypeless.app", category: "asr-llm")

/// LLM 语音转文字引擎。
///
/// 通过 LLM provider 的音频转写 API对整段录音文件做一次性识别。
/// - OpenAI-compatible transcription: `/v1/audio/transcriptions`
/// - Aliyun Qwen-ASR: `/compatible-mode/v1/chat/completions` + input_audio Data URL
///
/// 配置来自 `LLMConfig.asr*`（支持 Same as Text Model 或独立配置）。
final class LLMASR: ASREngine {
    enum ASError: LocalizedError {
        case notConfigured
        case unsupportedProvider(String)
        case requestFailed(String)
        case invalidResponse
        case emptyContent

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "ASR Model is not configured. Set API key / model in LLM settings."
            case .unsupportedProvider(let provider):
                return "ASR Model supports OpenAI-compatible transcription APIs and Aliyun Qwen-ASR. Unsupported provider: \(provider)."
            case .requestFailed(let message):
                return "ASR request failed: \(message)"
            case .invalidResponse:
                return "ASR returned an invalid response."
            case .emptyContent:
                return "ASR returned empty transcript."
            }
        }
    }

    private let session = URLSession.shared
    private let config: LLMConfig

    init(config: LLMConfig) {
        self.config = config
    }

    func transcribeFile(_ url: URL) async throws -> String {
        let requestConfig = effectiveASRConfig()

        guard requestConfig.apiKey.isEmpty == false else {
            throw ASError.notConfigured
        }

        switch try requestMode(provider: requestConfig.providerRaw, baseUrl: requestConfig.baseUrl, model: requestConfig.model) {
        case .openAITranscriptions:
            return try await transcribeOpenAICompatibleFile(url, config: requestConfig)
        case .aliyunQwenChatCompletions:
            return try await transcribeAliyunQwenFile(url, config: requestConfig)
        }
    }

    // MARK: - Provider Routing

    private enum RequestMode {
        case openAITranscriptions
        case aliyunQwenChatCompletions
    }

    private struct ASRRequestConfig {
        let providerRaw: String
        let apiKey: String
        let baseUrl: String
        let model: String
    }

    private func effectiveASRConfig() -> ASRRequestConfig {
        let useText = config.asrProviderSameAsText || config.asrProvider == "same"
        return ASRRequestConfig(
            providerRaw: useText ? config.textProvider : config.asrProvider,
            apiKey: (useText ? config.textApiKey : config.asrApiKey)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            baseUrl: useText ? config.textBaseUrl : config.asrBaseUrl,
            model: config.asrModel
        )
    }

    private func requestMode(provider providerRaw: String, baseUrl: String, model: String) throws -> RequestMode {
        let provider = providerRaw.lowercased()
        let model = model.lowercased()
        let baseUrl = baseUrl.lowercased()

        if provider == "aliyun" || provider == "dashscope" {
            return .aliyunQwenChatCompletions
        }
        if provider == "openai" {
            if isAliyunCompatibleBase(baseUrl) {
                return .aliyunQwenChatCompletions
            }
            if model.contains("qwen3-asr-flash") {
                throw ASError.requestFailed("qwen3-asr-flash requires Aliyun compatible-mode Base URL.")
            }
            return .openAITranscriptions
        }
        throw ASError.unsupportedProvider(providerRaw)
    }

    // MARK: - OpenAI-Compatible Transcription

    private func transcribeOpenAICompatibleFile(_ url: URL, config: ASRRequestConfig) async throws -> String {
        let endpoint = try makeTranscriptionURL(base: config.baseUrl)
        logger.info("LLMASR OpenAI-compatible request: model=\(config.model) file=\(url.lastPathComponent)")

        // multipart/form-data 上传音频文件
        let boundary = "OpenTypeless-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body = try makeMultipartBody(
            boundary: boundary,
            fileURL: url,
            model: config.model,
            filename: url.lastPathComponent
        )
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ASError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "(binary)"
            throw ASError.requestFailed("HTTP \(httpResponse.statusCode): \(String(bodyText.prefix(300)))")
        }

        // 响应格式：{"text": "..."}（OpenAI / GLM-ASR 兼容）
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw ASError.invalidResponse
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw ASError.emptyContent
        }
        logger.info("LLMASR result: \(trimmed.count) chars")
        return trimmed
    }

    // MARK: - Aliyun Qwen-ASR

    private func transcribeAliyunQwenFile(_ url: URL, config: ASRRequestConfig) async throws -> String {
        guard isAliyunCompatibleBase(config.baseUrl.lowercased()) else {
            throw ASError.requestFailed("Aliyun Qwen-ASR requires an Aliyun compatible-mode Base URL.")
        }
        guard config.model.lowercased().contains("qwen3-asr-flash") else {
            throw ASError.requestFailed("Aliyun Qwen-ASR currently supports qwen3-asr-flash.")
        }
        let endpoint = try makeAliyunChatCompletionsURL(base: config.baseUrl)
        logger.info("LLMASR Aliyun Qwen-ASR request: model=\(config.model) file=\(url.lastPathComponent)")

        let dataURL = try makeAudioDataURL(fileURL: url)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": config.model.isEmpty ? "qwen3-asr-flash" : config.model,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_audio",
                            "input_audio": [
                                "data": dataURL
                            ]
                        ]
                    ]
                ]
            ],
            "stream": false,
            "asr_options": [
                "enable_itn": false
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ASError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "(binary)"
            throw ASError.requestFailed("HTTP \(httpResponse.statusCode): \(String(bodyText.prefix(300)))")
        }

        let text = try extractChatCompletionText(from: data)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw ASError.emptyContent
        }
        logger.info("LLMASR Aliyun result: \(trimmed.count) chars")
        return trimmed
    }

    // MARK: - Helpers

    /// 拼接 base URL + /audio/transcriptions，容忍 base 含 /v1。
    private func makeTranscriptionURL(base: String) throws -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix("/v1") {
            trimmed = String(trimmed.dropLast(3))
        }
        guard let url = URL(string: trimmed + "/v1/audio/transcriptions") else {
            throw ASError.requestFailed("Invalid URL: \(trimmed)/v1/audio/transcriptions")
        }
        return url
    }

    /// 拼接阿里 OpenAI-compatible chat completions URL，容忍 base 含 /v1 或完整 endpoint。
    private func makeAliyunChatCompletionsURL(base: String) throws -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint: String
        if trimmed.hasSuffix("/chat/completions") {
            endpoint = trimmed
        } else if trimmed.hasSuffix("/v1") {
            endpoint = trimmed + "/chat/completions"
        } else {
            endpoint = trimmed + "/v1/chat/completions"
        }
        guard let url = URL(string: endpoint) else {
            throw ASError.requestFailed("Invalid URL: \(endpoint)")
        }
        return url
    }

    private func isAliyunCompatibleBase(_ baseUrl: String) -> Bool {
        baseUrl.contains("aliyuncs.com/compatible-mode")
            || baseUrl.hasSuffix("/chat/completions")
    }

    private func makeAudioDataURL(fileURL: URL) throws -> String {
        let audioData = try Data(contentsOf: fileURL)
        let mime = mimeType(for: fileURL.lastPathComponent)
        let base64 = audioData.base64EncodedString()
        let dataURL = "data:\(mime);base64,\(base64)"
        let maxEncodedSize = 10 * 1024 * 1024
        guard dataURL.utf8.count <= maxEncodedSize else {
            throw ASError.requestFailed("Aliyun Qwen-ASR supports Base64 audio up to 10 MB. Try a shorter recording.")
        }
        return dataURL
    }

    private func extractChatCompletionText(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw ASError.invalidResponse
        }
        if let text = message["content"] as? String {
            return text
        }
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { part in
                part["text"] as? String ?? part["content"] as? String
            }.joined()
            if text.isEmpty == false {
                return text
            }
        }
        throw ASError.invalidResponse
    }

    /// 构建 multipart/form-data 请求体。
    private func makeMultipartBody(
        boundary: String,
        fileURL: URL,
        model: String,
        filename: String
    ) throws -> Data {
        var body = Data()

        // model 字段
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

        // stream 字段（智谱 GLM-ASR 默认 false）
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"stream\"\r\n\r\n".data(using: .utf8)!)
        body.append("false\r\n".data(using: .utf8)!)

        // file 字段
        let audioData = try Data(contentsOf: fileURL)
        let mime = mimeType(for: filename)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // 结束边界
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "aac": return "audio/aac"
        default:    return "application/octet-stream"
        }
    }
}
