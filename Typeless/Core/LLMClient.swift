import Foundation
import os.log

private let logger = Logger(subsystem: "com.typeless.app", category: "llm")

/// LLM 客户端：移植 PTerminal ai/client.rs 的双协议抽象，支持 OpenAI / Anthropic。
///
/// 两种用途：
/// - 文字模型（translate）：B 键翻译
/// - 多模态模型（assist）：C 键处理（含选中文本 + 剪贴板图片）
///
/// 协议差异：
/// - OpenAI: POST {base}/v1/chat/completions, body={model,messages}, header=Authorization: Bearer {key}
/// - Anthropic: POST {base}/v1/messages, body={model,messages,system,max_tokens}, header=x-api-key + anthropic-version
final class LLMClient {
    enum LLMError: LocalizedError {
        case notConfigured
        case requestFailed(String)
        case invalidResponse
        case emptyContent

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "LLM is not configured. Set API key in settings."
            case .requestFailed(let message):
                return "LLM request failed: \(message)"
            case .invalidResponse:
                return "LLM returned an invalid response."
            case .emptyContent:
                return "LLM returned empty content."
            }
        }
    }

    enum Provider: String, Codable {
        case openai
        case anthropic

        var path: String {
            switch self {
            case .openai:    return "/v1/chat/completions"
            case .anthropic: return "/v1/messages"
            }
        }
    }

    private let session = URLSession.shared

    /// 共享的语音转写加工提示词（A 键加工、B 键翻译前加工都复用）。
    private static let refinePrompt = """
    你是语音转写文字的整理助手。对下面的转写文字进行加工：\
    1. 自动去除像“呃”、“嗯”等填充词。\
    2. 去除讲话中不必要和重复的词汇，确保语言简洁易懂。\
    3. 将口述的列表、步骤和要点整理成干净、结构化的文本，省去手动格式化的麻烦。\
    保留原意，不添加未提及的信息。
    """

    // MARK: - Refine (Text Model, A key 后处理)

    /// 加工语音转写文字：去填充词、去重复、结构化整理。
    /// 仅在配置了 Text Model 时调用；未配置应直接返回原始文字（调用方判断）。
    func refine(_ raw: String, using config: LLMConfig) async throws -> String {
        let apiKey = config.textApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey.isEmpty == false || isLocalProvider(config.textProvider) else {
            throw LLMError.notConfigured
        }

        let provider = Provider(rawValue: config.textProvider) ?? .openai
        let systemPrompt = Self.refinePrompt + "直接返回加工后的文字，不要任何解释或前后缀。"

        let messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": raw]
        ]

        return try await chatCompletion(
            provider: provider,
            baseUrl: config.textBaseUrl,
            apiKey: apiKey,
            model: config.textModel,
            messages: messages,
            temperature: 0.2
        )
    }

    // MARK: - Translate (Text Model, B key)

    /// 翻译文本到目标语言。
    func translate(_ text: String, to targetLanguage: String, using config: LLMConfig) async throws -> String {
        let apiKey = config.textApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey.isEmpty == false || isLocalProvider(config.textProvider) else {
            throw LLMError.notConfigured
        }

        let provider = Provider(rawValue: config.textProvider) ?? .openai
        let systemPrompt = Self.refinePrompt + "\n另外，请将加工后的文字翻译成\(targetLanguage)。如果原文已经是\(targetLanguage)，则保持不变。直接返回加工并翻译后的最终结果，不要任何解释或前后缀。"

        let messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": text]
        ]

        let result = try await chatCompletion(
            provider: provider,
            baseUrl: config.textBaseUrl,
            apiKey: apiKey,
            model: config.textModel,
            messages: messages,
            temperature: 0.1
        )
        logger.info("Translated \(text.count) chars to \(targetLanguage)")
        return result
    }

    // MARK: - Assist (Vision Model, C key)

    /// 多模态处理：转写文字 + 上下文（选中文本 + 剪贴板图片/文字）。
    ///
    /// 模型选择逻辑：
    /// - 有图片 → 用 Vision Model（多模态），需 Vision 配置可用，否则降级到 Text Model（丢图片）
    /// - 无图片 → 用 Text Model（文字）
    func assist(
        transcription: String,
        context: ContextCollector.CollectedContext,
        using config: LLMConfig
    ) async throws -> String {
        let hasImage = context.clipboardImage != nil

        // 解析 effective 配置：有图片用 vision，否则用 text
        let providerRaw: String
        let apiKey: String
        let baseUrl: String
        let model: String

        if hasImage {
            let useText = config.visionProviderSameAsText || config.visionProvider == "same"
            providerRaw = useText ? config.textProvider : config.visionProvider
            apiKey = (useText ? config.textApiKey : config.visionApiKey)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            baseUrl = useText ? config.textBaseUrl : config.visionBaseUrl
            model = config.visionModel
        } else {
            providerRaw = config.textProvider
            apiKey = config.textApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            baseUrl = config.textBaseUrl
            model = config.textModel
        }

        guard apiKey.isEmpty == false || isLocalProvider(providerRaw) else {
            throw LLMError.notConfigured
        }

        let provider = Provider(rawValue: providerRaw) ?? .openai

        let systemPrompt = """
        You are a helpful assistant. The user spoke (transcribed below) and may have provided \
        additional context (selected text, clipboard image/text). Respond concisely and helpfully. \
        Respond in the same language the user spoke.
        """

        // 构建消息内容
        var userContent = "Spoken text: \(transcription)"

        if let selected = context.selectedText, selected.isEmpty == false {
            userContent += "\n\nSelected text: \(selected)"
        }
        if let clipboardText = context.clipboardText, clipboardText.isEmpty == false {
            userContent += "\n\nClipboard text: \(clipboardText)"
        }

        let messages: [[String: Any]]
        if let imageData = context.clipboardImage {
            // 有图片：用多模态格式
            let imageBase64 = imageData.base64EncodedString()
            messages = [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": [
                    ["type": "text", "text": userContent],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(imageBase64)"]]
                ]]
            ]
            logger.info("Assist with image (\(imageData.count) bytes) + text [\(providerRaw)/\(model)]")
        } else {
            // 纯文字
            messages = [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ]
            logger.info("Assist text only [\(providerRaw)/\(model)]")
        }

        let result = try await chatCompletion(
            provider: provider,
            baseUrl: baseUrl,
            apiKey: apiKey,
            model: model,
            messages: messages,
            temperature: 0.7
        )
        return result
    }

    // MARK: - Core: Chat Completion

    /// 统一的 chat completion 入口，根据 provider 分发到不同协议。
    private func chatCompletion(
        provider: Provider,
        baseUrl: String,
        apiKey: String,
        model: String,
        messages: [[String: Any]],
        temperature: Double
    ) async throws -> String {
        let url = try joinApiUrl(base: baseUrl, path: provider.path)
        logger.info("LLM request: \(provider.rawValue) \(url.path) model=\(model)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        switch provider {
        case .openai:
            if apiKey.isEmpty == false {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            let body: [String: Any] = [
                "model": model,
                "messages": messages,
                "temperature": temperature,
                "stream": false
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

        case .anthropic:
            if apiKey.isEmpty == false {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            // Anthropic: system 单独提取，messages 只有 user/assistant
            var systemText = ""
            var convoMessages: [[String: Any]] = []
            for msg in messages {
                if (msg["role"] as? String) == "system" {
                    if let content = msg["content"] as? String {
                        systemText += (systemText.isEmpty ? "" : "\n\n") + content
                    }
                } else {
                    convoMessages.append(msg)
                }
            }

            var body: [String: Any] = [
                "model": model,
                "messages": convoMessages,
                "max_tokens": 4096,
                "temperature": temperature,
                "stream": false
            ]
            if systemText.isEmpty == false {
                body["system"] = systemText
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "(binary)"
            throw LLMError.requestFailed("HTTP \(httpResponse.statusCode): \(String(bodyText.prefix(300)))")
        }

        // 解析响应（OpenAI 和 Anthropic 格式不同）
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.invalidResponse
        }

        let content: String?
        switch provider {
        case .openai:
            // OpenAI: choices[0].message.content
            if let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let text = message["content"] as? String {
                content = text
            } else {
                content = nil
            }
        case .anthropic:
            // Anthropic: content[0].text
            content = (json["content"] as? [[String: Any]])?
                .first?["text"] as? String
        }

        guard let raw = content?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.isEmpty == false else {
            throw LLMError.emptyContent
        }
        // 过滤 <think>...</think> 思考过程标签（深度思考模型如 DeepSeek-R1 会输出）
        let text = Self.stripThinkTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else {
            throw LLMError.emptyContent
        }
        return text
    }

    /// 移除大模型输出中的 <think>...</think> 思考过程标签。
    /// 处理：成对标签（含多行）、未闭合的开标签（到文末）。
    private static func stripThinkTags(_ text: String) -> String {
        var result = text
        // 成对的 <think>...</think>（DOTALL：跨行匹配），非贪婪
        if let regex = try? NSRegularExpression(pattern: "<think>.*?</think>", options: [.dotMatchesLineSeparators]) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        // 残留的未闭合 <think>（从开标签到字符串结尾）
        if let regex = try? NSRegularExpression(pattern: "<think>.*", options: [.dotMatchesLineSeparators]) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        return result
    }

    // MARK: - Helpers

    /// 拼接 base URL 和 API path，容忍 base 含 /v1。
    /// 参照 PTerminal join_api_url：strip trailing /v1 避免重复。
    private func joinApiUrl(base: String, path: String) throws -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix("/v1") {
            trimmed = String(trimmed.dropLast(3))
        }
        guard let url = URL(string: trimmed + path) else {
            throw LLMError.requestFailed("Invalid URL: \(trimmed)\(path)")
        }
        return url
    }

    /// 判断是否本地 provider（Ollama / LM Studio），这类不需要 API key。
    private func isLocalProvider(_ provider: String) -> Bool {
        let lower = provider.lowercased()
        return lower == "ollama" || lower == "lm-studio" || lower == "local"
    }

    // MARK: - Test Connection (for settings UI)

    /// 测试连接：发送最小请求验证 provider 可达 + key 有效。
    /// - Parameters:
    ///   - config: LLM 配置
    ///   - useVisionConfig: true 时测试 Vision Model 配置
    ///   - useASRConfig: true 时测试 ASR Model 配置
    func testConnection(config: LLMConfig, useVisionConfig: Bool = false, useASRConfig: Bool = false) async -> TestResult {
        let providerRaw: String
        let apiKey: String
        let model: String
        let baseUrl: String

        if useASRConfig {
            let useText = config.asrProviderSameAsText
            providerRaw = useText ? config.textProvider : config.asrProvider
            apiKey = useText ? config.textApiKey : config.asrApiKey
            model = config.asrModel
            baseUrl = useText ? config.textBaseUrl : config.asrBaseUrl
        } else if useVisionConfig {
            let useText = config.visionProviderSameAsText
            providerRaw = useText ? config.textProvider : config.visionProvider
            apiKey = useText ? config.textApiKey : config.visionApiKey
            model = config.visionModel
            baseUrl = useText ? config.textBaseUrl : config.visionBaseUrl
        } else {
            providerRaw = config.textProvider
            apiKey = config.textApiKey
            model = config.textModel
            baseUrl = config.textBaseUrl
        }

        let provider = Provider(rawValue: providerRaw) ?? .openai

        do {
            _ = try await chatCompletion(
                provider: provider,
                baseUrl: baseUrl,
                apiKey: apiKey,
                model: model,
                messages: [["role": "user", "content": "hi"]],
                temperature: 0
            )
            return TestResult(ok: true, message: "Connected (model: \(model))")
        } catch let error as LLMError {
            return TestResult(ok: false, message: error.localizedDescription)
        } catch {
            return TestResult(ok: false, message: error.localizedDescription)
        }
    }

    struct TestResult {
        let ok: Bool
        let message: String
    }
}
