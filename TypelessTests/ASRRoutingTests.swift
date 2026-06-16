import XCTest
@testable import OpenTypeless

final class ASRRoutingTests: XCTestCase {

    // MARK: - requestMode

    func testRequestMode_Aliyun() throws {
        let asr = LLMASR(config: LLMConfig())
        let mode = try asr.requestMode(
            provider: "aliyun",
            baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            model: "qwen3-asr-flash"
        )
        XCTAssertEqual(mode, .aliyunQwenChatCompletions)
    }

    func testRequestMode_DashScope() throws {
        let asr = LLMASR(config: LLMConfig())
        let mode = try asr.requestMode(
            provider: "dashscope",
            baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            model: "qwen3-asr-flash"
        )
        XCTAssertEqual(mode, .aliyunQwenChatCompletions)
    }

    func testRequestMode_OpenAI() throws {
        let asr = LLMASR(config: LLMConfig())
        let mode = try asr.requestMode(provider: "openai", baseUrl: "https://api.openai.com", model: "whisper-1")
        XCTAssertEqual(mode, .openAITranscriptions)
    }

    func testRequestMode_OpenAIWithAliyunBase() throws {
        let asr = LLMASR(config: LLMConfig())
        let mode = try asr.requestMode(
            provider: "openai",
            baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            model: "qwen3-asr-flash"
        )
        XCTAssertEqual(mode, .aliyunQwenChatCompletions)
    }

    func testRequestMode_OpenAIWithChatCompletionsSuffix() throws {
        let asr = LLMASR(config: LLMConfig())
        let mode = try asr.requestMode(
            provider: "openai",
            baseUrl: "https://example.com/v1/chat/completions",
            model: "qwen3-asr-flash"
        )
        XCTAssertEqual(mode, .aliyunQwenChatCompletions)
    }

    func testRequestMode_OpenAIQwenModelWrongBase() {
        let asr = LLMASR(config: LLMConfig())
        XCTAssertThrowsError(try asr.requestMode(provider: "openai", baseUrl: "https://api.openai.com", model: "qwen3-asr-flash"))
    }

    func testRequestMode_AnthropicUnsupported() {
        let asr = LLMASR(config: LLMConfig())
        XCTAssertThrowsError(try asr.requestMode(provider: "anthropic", baseUrl: "https://api.anthropic.com", model: "claude")) { error in
            guard case LLMASR.ASError.unsupportedProvider(let name) = error else {
                XCTFail("Expected unsupportedProvider, got \(error)")
                return
            }
            XCTAssertEqual(name, "anthropic")
        }
    }

    func testRequestMode_UnknownProvider() {
        let asr = LLMASR(config: LLMConfig())
        XCTAssertThrowsError(try asr.requestMode(provider: "ollama", baseUrl: "http://localhost", model: "model")) { error in
            guard case LLMASR.ASError.unsupportedProvider = error else {
                XCTFail("Expected unsupportedProvider, got \(error)")
                return
            }
        }
    }

    // MARK: - makeTranscriptionURL

    func testMakeTranscriptionURL_Normal() throws {
        let asr = LLMASR(config: LLMConfig())
        let url = try asr.makeTranscriptionURL(base: "https://api.openai.com")
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
    }

    func testMakeTranscriptionURL_WithV1() throws {
        let asr = LLMASR(config: LLMConfig())
        let url = try asr.makeTranscriptionURL(base: "https://api.openai.com/v1")
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
    }

    func testMakeTranscriptionURL_WithTrailingSlash() throws {
        let asr = LLMASR(config: LLMConfig())
        let url = try asr.makeTranscriptionURL(base: "https://api.openai.com/")
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
    }

    func testMakeTranscriptionURL_WithV1AndSlash() throws {
        let asr = LLMASR(config: LLMConfig())
        let url = try asr.makeTranscriptionURL(base: "https://api.openai.com/v1/")
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
    }

    func testMakeTranscriptionURL_CustomBase() throws {
        let asr = LLMASR(config: LLMConfig())
        let url = try asr.makeTranscriptionURL(base: "https://api.deepseek.com")
        XCTAssertEqual(url.absoluteString, "https://api.deepseek.com/v1/audio/transcriptions")
    }

    // MARK: - makeAliyunChatCompletionsURL

    func testMakeAliyunURL_Normal() throws {
        let asr = LLMASR(config: LLMConfig())
        let url = try asr.makeAliyunChatCompletionsURL(base: "https://dashscope.aliyuncs.com/compatible-mode/v1")
        XCTAssertEqual(url.absoluteString, "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
    }

    func testMakeAliyunURL_WithChatCompletions() throws {
        let asr = LLMASR(config: LLMConfig())
        let url = try asr.makeAliyunChatCompletionsURL(base: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
        XCTAssertEqual(url.absoluteString, "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
    }

    func testMakeAliyunURL_BaseOnly() throws {
        let asr = LLMASR(config: LLMConfig())
        let url = try asr.makeAliyunChatCompletionsURL(base: "https://dashscope.aliyuncs.com/compatible-mode")
        XCTAssertEqual(url.absoluteString, "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
    }

    func testMakeAliyunURL_TrailingSlash() throws {
        let asr = LLMASR(config: LLMConfig())
        let url = try asr.makeAliyunChatCompletionsURL(base: "https://dashscope.aliyuncs.com/compatible-mode/v1/")
        XCTAssertEqual(url.absoluteString, "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
    }

    // MARK: - mimeType

    func testMimeType_M4A() {
        let asr = LLMASR(config: LLMConfig())
        XCTAssertEqual(asr.mimeType(for: "recording.m4a"), "audio/mp4")
    }

    func testMimeType_WAV() {
        let asr = LLMASR(config: LLMConfig())
        XCTAssertEqual(asr.mimeType(for: "audio.wav"), "audio/wav")
    }

    func testMimeType_MP3() {
        let asr = LLMASR(config: LLMConfig())
        XCTAssertEqual(asr.mimeType(for: "song.mp3"), "audio/mpeg")
    }

    func testMimeType_AAC() {
        let asr = LLMASR(config: LLMConfig())
        XCTAssertEqual(asr.mimeType(for: "stream.aac"), "audio/aac")
    }

    func testMimeType_Unknown() {
        let asr = LLMASR(config: LLMConfig())
        XCTAssertEqual(asr.mimeType(for: "file.ogg"), "application/octet-stream")
    }

    func testMimeType_NoExtension() {
        let asr = LLMASR(config: LLMConfig())
        XCTAssertEqual(asr.mimeType(for: "noextension"), "application/octet-stream")
    }

    func testMimeType_CaseInsensitive() {
        let asr = LLMASR(config: LLMConfig())
        XCTAssertEqual(asr.mimeType(for: "recording.M4A"), "audio/mp4")
    }
}
