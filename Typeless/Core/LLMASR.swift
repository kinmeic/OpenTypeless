import Foundation
import os.log

private let logger = Logger(subsystem: "com.opentypeless.app", category: "asr-llm")

/// LLM 语音转文字引擎。
///
/// 通过 LLM provider 的音频转写 API（兼容 OpenAI `/v1/audio/transcriptions` 格式，
/// 如智谱 GLM-ASR-2512）对整段录音文件做一次性识别。
///
/// 配置来自 `LLMConfig.asr*`（支持 Same as Text Model 或独立配置）。
final class LLMASR: ASREngine {
    enum ASError: LocalizedError {
        case notConfigured
        case requestFailed(String)
        case invalidResponse
        case emptyContent

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "ASR Model is not configured. Set API key / model in LLM settings."
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
        // 解析 effective provider / apiKey / baseUrl / model（处理 Same as Text Model）
        let useText = config.asrProviderSameAsText || config.asrProvider == "same"
        let providerRaw = useText ? config.textProvider : config.asrProvider
        let apiKey = (useText ? config.textApiKey : config.asrApiKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseUrl = useText ? config.textBaseUrl : config.asrBaseUrl
        let model = config.asrModel

        guard apiKey.isEmpty == false else {
            throw ASError.notConfigured
        }

        let endpoint = try makeTranscriptionURL(base: baseUrl)
        logger.info("LLMASR request: provider=\(providerRaw) model=\(model) file=\(url.lastPathComponent)")

        // multipart/form-data 上传音频文件
        let boundary = "OpenTypeless-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body = try makeMultipartBody(
            boundary: boundary,
            fileURL: url,
            model: model,
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
