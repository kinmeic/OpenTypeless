import XCTest
@testable import OpenTypeless

final class LLMClientParsingTests: XCTestCase {

    private let client = LLMClient()

    // MARK: - stripThinkTags

    func testStripThinkTags_NoTags() {
        XCTAssertEqual(LLMClient.stripThinkTags("Hello world"), "Hello world")
    }

    func testStripThinkTags_PairedTags() {
        XCTAssertEqual(
            LLMClient.stripThinkTags("<think>thinking process</think>Hello world"),
            "Hello world"
        )
    }

    func testStripThinkTags_MultilineThinkTags() {
        let input = "<think>\nline 1\nline 2\n</think>Actual answer"
        XCTAssertEqual(LLMClient.stripThinkTags(input), "Actual answer")
    }

    func testStripThinkTags_UnclosedTag() {
        let input = "Some text<think>unclosed thinking"
        XCTAssertEqual(LLMClient.stripThinkTags(input), "Some text")
    }

    func testStripThinkTags_MultipleThinkTags() {
        let input = "<think>first</think>Hello <think>second</think>world"
        XCTAssertEqual(LLMClient.stripThinkTags(input), "Hello world")
    }

    func testStripThinkTags_EmptyThinkTags() {
        XCTAssertEqual(LLMClient.stripThinkTags("<think></think>Result"), "Result")
    }

    func testStripThinkTags_EmptyString() {
        XCTAssertEqual(LLMClient.stripThinkTags(""), "")
    }

    func testStripThinkTags_OnlyThinkTag() {
        XCTAssertEqual(LLMClient.stripThinkTags("<think>just thinking</think>"), "")
    }

    // MARK: - joinApiUrl

    func testJoinApiUrl_OpenAI() throws {
        let url = try client.joinApiUrl(base: "https://api.openai.com", path: "/v1/chat/completions")
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    func testJoinApiUrl_BaseWithV1Suffix() throws {
        let url = try client.joinApiUrl(base: "https://api.openai.com/v1", path: "/v1/chat/completions")
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    func testJoinApiUrl_BaseWithTrailingSlash() throws {
        let url = try client.joinApiUrl(base: "https://api.openai.com/", path: "/v1/chat/completions")
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    func testJoinApiUrl_Anthropic() throws {
        let url = try client.joinApiUrl(base: "https://api.anthropic.com", path: "/v1/messages")
        XCTAssertEqual(url.absoluteString, "https://api.anthropic.com/v1/messages")
    }

    func testJoinApiUrl_AnthropicWithV1() throws {
        let url = try client.joinApiUrl(base: "https://api.anthropic.com/v1", path: "/v1/messages")
        XCTAssertEqual(url.absoluteString, "https://api.anthropic.com/v1/messages")
    }

    func testJoinApiUrl_Localhost() throws {
        let url = try client.joinApiUrl(base: "http://localhost:11434", path: "/v1/chat/completions")
        XCTAssertEqual(url.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    func testJoinApiUrl_WhitespaceTrimming() throws {
        let url = try client.joinApiUrl(base: "  https://api.openai.com  ", path: "/v1/chat/completions")
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    func testJoinApiUrl_BaseWithV1AndTrailingSlash() throws {
        let url = try client.joinApiUrl(base: "https://api.openai.com/v1/", path: "/v1/chat/completions")
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    // MARK: - isLocalProvider

    func testIsLocalProvider_Ollama() {
        XCTAssertTrue(client.isLocalProvider("ollama"))
        XCTAssertTrue(client.isLocalProvider("Ollama"))
        XCTAssertTrue(client.isLocalProvider("OLLAMA"))
    }

    func testIsLocalProvider_LMStudio() {
        XCTAssertTrue(client.isLocalProvider("lm-studio"))
        XCTAssertTrue(client.isLocalProvider("LM-Studio"))
    }

    func testIsLocalProvider_Local() {
        XCTAssertTrue(client.isLocalProvider("local"))
    }

    func testIsLocalProvider_NotLocal() {
        XCTAssertFalse(client.isLocalProvider("openai"))
        XCTAssertFalse(client.isLocalProvider("anthropic"))
        XCTAssertFalse(client.isLocalProvider("aliyun"))
        XCTAssertFalse(client.isLocalProvider(""))
    }

    // MARK: - resolveProvider

    func testResolveProvider_OpenAI() throws {
        let provider = try client.resolveProvider("openai")
        XCTAssertEqual(provider, .openai)
    }

    func testResolveProvider_Anthropic() throws {
        let provider = try client.resolveProvider("anthropic")
        XCTAssertEqual(provider, .anthropic)
    }

    func testResolveProvider_OllamaFallsBackToOpenAI() throws {
        let provider = try client.resolveProvider("ollama")
        XCTAssertEqual(provider, .openai)
    }

    func testResolveProvider_LMStudioFallsBackToOpenAI() throws {
        let provider = try client.resolveProvider("lm-studio")
        XCTAssertEqual(provider, .openai)
    }

    func testResolveProvider_LocalFallsBackToOpenAI() throws {
        let provider = try client.resolveProvider("local")
        XCTAssertEqual(provider, .openai)
    }

    func testResolveProvider_UnknownThrows() {
        XCTAssertThrowsError(try client.resolveProvider("mistral")) { error in
            guard case LLMClient.LLMError.unknownProvider(let name) = error else {
                XCTFail("Expected unknownProvider, got \(error)")
                return
            }
            XCTAssertEqual(name, "mistral")
        }
    }

    func testResolveProvider_EmptyThrows() {
        XCTAssertThrowsError(try client.resolveProvider(""))
    }

    // MARK: - validateASRSettings

    func testValidateASR_EmptyApiKey() {
        let r = client.validateASRSettings(providerRaw: "openai", apiKey: "", model: "whisper-1", baseUrl: "https://api.openai.com")
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("API key"))
    }

    func testValidateASR_WhitespaceOnlyApiKey() {
        let r = client.validateASRSettings(providerRaw: "openai", apiKey: "   ", model: "whisper-1", baseUrl: "https://api.openai.com")
        XCTAssertFalse(r.ok)
    }

    func testValidateASR_EmptyModel() {
        let r = client.validateASRSettings(providerRaw: "openai", apiKey: "key", model: "", baseUrl: "https://api.openai.com")
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("model"))
    }

    func testValidateASR_InvalidBaseURL() {
        let r = client.validateASRSettings(providerRaw: "openai", apiKey: "key", model: "whisper-1", baseUrl: "not a url")
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("Base URL"))
    }

    func testValidateASR_AliyunValid() {
        let r = client.validateASRSettings(
            providerRaw: "aliyun", apiKey: "key", model: "qwen3-asr-flash",
            baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        XCTAssertTrue(r.ok)
    }

    func testValidateASR_AliyunWrongBaseURL() {
        let r = client.validateASRSettings(providerRaw: "aliyun", apiKey: "key", model: "qwen3-asr-flash", baseUrl: "https://api.openai.com")
        XCTAssertFalse(r.ok)
    }

    func testValidateASR_AliyunWrongModel() {
        let r = client.validateASRSettings(
            providerRaw: "aliyun", apiKey: "key", model: "whisper-1",
            baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        XCTAssertFalse(r.ok)
    }

    func testValidateASR_OpenAIValid() {
        let r = client.validateASRSettings(providerRaw: "openai", apiKey: "key", model: "whisper-1", baseUrl: "https://api.openai.com")
        XCTAssertTrue(r.ok)
    }

    func testValidateASR_OpenAIWithQwenModel() {
        let r = client.validateASRSettings(providerRaw: "openai", apiKey: "key", model: "qwen3-asr-flash", baseUrl: "https://api.openai.com")
        XCTAssertFalse(r.ok)
    }

    func testValidateASR_OpenAIWithAliyunBaseAndQwenModel() {
        let r = client.validateASRSettings(
            providerRaw: "openai", apiKey: "key", model: "qwen3-asr-flash",
            baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        XCTAssertTrue(r.ok)
    }

    func testValidateASR_UnsupportedProvider() {
        let r = client.validateASRSettings(providerRaw: "anthropic", apiKey: "key", model: "model", baseUrl: "https://api.anthropic.com")
        XCTAssertFalse(r.ok)
    }

    func testValidateASR_DashScopeProvider() {
        let r = client.validateASRSettings(
            providerRaw: "dashscope", apiKey: "key", model: "qwen3-asr-flash",
            baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        XCTAssertTrue(r.ok)
    }
}
