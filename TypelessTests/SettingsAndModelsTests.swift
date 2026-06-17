import XCTest
import AppKit
@testable import OpenTypeless

final class SettingsAndModelsTests: XCTestCase {

    // MARK: - LLMConfig Defaults

    func testLLMConfig_Defaults() {
        let config = LLMConfig()
        XCTAssertEqual(config.textProvider, "openai")
        XCTAssertEqual(config.textApiKey, "")
        XCTAssertEqual(config.textModel, "gpt-4o-mini")
        XCTAssertEqual(config.textBaseUrl, "https://api.openai.com")
        XCTAssertEqual(config.asrProvider, "same")
        XCTAssertEqual(config.asrModel, "gpt-4o-mini")
        XCTAssertEqual(config.asrBaseUrl, "https://api.openai.com")
        XCTAssertTrue(config.asrProviderSameAsText)
    }

    func testLLMConfig_CodableRoundtrip() throws {
        var config = LLMConfig()
        config.textProvider = "anthropic"
        config.textApiKey = "test-key"
        config.textModel = "claude-3"
        config.asrProvider = "aliyun"
        config.asrProviderSameAsText = false

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(LLMConfig.self, from: data)
        XCTAssertEqual(decoded.textProvider, "anthropic")
        XCTAssertEqual(decoded.textApiKey, "test-key")
        XCTAssertEqual(decoded.textModel, "claude-3")
        XCTAssertEqual(decoded.asrProvider, "aliyun")
        XCTAssertFalse(decoded.asrProviderSameAsText)
    }

    func testLLMConfig_Equatable() {
        let a = LLMConfig()
        let b = LLMConfig()
        XCTAssertEqual(a, b)

        var c = LLMConfig()
        c.textModel = "gpt-4"
        XCTAssertNotEqual(a, c)
    }

    // MARK: - ASRConfig Defaults

    func testASRConfig_Defaults() {
        let config = ASRConfig()
        XCTAssertEqual(config.engine, .systemSpeech)
        XCTAssertEqual(config.recognitionLanguageID, "zh-CN")
    }

    // MARK: - ASRConfig Legacy Migration

    func testASRConfig_LegacyLanguageIDsMigration() throws {
        let json: [String: Any] = ["languageIDs": ["en-US", "zh-CN"], "engine": "system"]
        let data = try JSONSerialization.data(withJSONObject: json)
        let config = try JSONDecoder().decode(ASRConfig.self, from: data)
        XCTAssertEqual(config.recognitionLanguageID, "en-US")
    }

    func testASRConfig_LegacyEmptyLanguageIDs() throws {
        let json: [String: Any] = ["languageIDs": [], "engine": "system"]
        let data = try JSONSerialization.data(withJSONObject: json)
        let config = try JSONDecoder().decode(ASRConfig.self, from: data)
        XCTAssertEqual(config.recognitionLanguageID, "zh-CN")
    }

    func testASRConfig_NewFormatTakesPrecedence() throws {
        let json: [String: Any] = [
            "recognitionLanguageID": "ja-JP",
            "languageIDs": ["en-US"],
            "engine": "llm"
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let config = try JSONDecoder().decode(ASRConfig.self, from: data)
        XCTAssertEqual(config.recognitionLanguageID, "ja-JP")
        XCTAssertEqual(config.engine, .llm)
    }

    func testASRConfig_MissingBothFallsBackToDefault() throws {
        let json: [String: Any] = ["engine": "system"]
        let data = try JSONSerialization.data(withJSONObject: json)
        let config = try JSONDecoder().decode(ASRConfig.self, from: data)
        XCTAssertEqual(config.recognitionLanguageID, "zh-CN")
    }

    func testASRConfig_CodableRoundtrip() throws {
        let config = ASRConfig(engine: .llm, recognitionLanguageID: "ja-JP")
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ASRConfig.self, from: data)
        XCTAssertEqual(decoded.engine, .llm)
        XCTAssertEqual(decoded.recognitionLanguageID, "ja-JP")
    }

    func testASRConfig_EncodeOmitsLegacyKey() throws {
        let config = ASRConfig(engine: .systemSpeech, recognitionLanguageID: "en-US")
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(json?["languageIDs"])
        XCTAssertEqual(json?["recognitionLanguageID"] as? String, "en-US")
    }

    // MARK: - ShortcutConfig Defaults

    func testShortcutConfig_Defaults() {
        let config = ShortcutConfig()
        XCTAssertEqual(config.role, "A")
        XCTAssertEqual(config.keyCode, 0)
        XCTAssertEqual(config.modifierFlags, 0)
    }

    func testShortcutConfig_CodableRoundtrip() throws {
        let config = ShortcutConfig(role: "B", keyCode: 0x13, modifierFlags: Int(NSEvent.ModifierFlags.option.rawValue))
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ShortcutConfig.self, from: data)
        XCTAssertEqual(decoded.role, "B")
        XCTAssertEqual(decoded.keyCode, 0x13)
        XCTAssertEqual(decoded.modifierFlags, Int(NSEvent.ModifierFlags.option.rawValue))
    }

    // MARK: - ShortcutsConfig Defaults

    func testShortcutsConfig_Defaults() {
        let config = ShortcutsConfig()
        XCTAssertEqual(config.a.role, "A")
        XCTAssertEqual(config.b.role, "B")
        XCTAssertEqual(config.c.role, "C")
        XCTAssertNotEqual(config.a.keyCode, config.b.keyCode)
        XCTAssertNotEqual(config.b.keyCode, config.c.keyCode)
    }

    // MARK: - ASREngineType

    func testASREngineType_RawValues() {
        XCTAssertEqual(ASREngineType.systemSpeech.rawValue, "system")
        XCTAssertEqual(ASREngineType.llm.rawValue, "llm")
    }

    func testASREngineType_AllCases() {
        XCTAssertEqual(ASREngineType.allCases.count, 2)
        XCTAssertTrue(ASREngineType.allCases.contains(.systemSpeech))
        XCTAssertTrue(ASREngineType.allCases.contains(.llm))
    }

    func testASREngineType_CodableRoundtrip() throws {
        let data = try JSONEncoder().encode(ASREngineType.llm)
        let decoded = try JSONDecoder().decode(ASREngineType.self, from: data)
        XCTAssertEqual(decoded, .llm)
    }

    // MARK: - ASRLanguage

    func testASRLanguage_Identifiable() {
        let lang = ASRLanguage(id: "zh-CN", name: "中文")
        XCTAssertEqual(lang.id, "zh-CN")
    }

    func testASRLanguage_Equatable() {
        let a = ASRLanguage(id: "en-US", name: "English")
        let b = ASRLanguage(id: "en-US", name: "English")
        XCTAssertEqual(a, b)
    }

    func testASRLanguage_SupportedLanguages() {
        XCTAssertFalse(ASRConfig.supportedSystemLanguages.isEmpty)
        let ids = ASRConfig.supportedSystemLanguages.map(\.id)
        XCTAssertTrue(ids.contains("zh-CN"))
        XCTAssertTrue(ids.contains("en-US"))
    }

    // MARK: - Pipeline.Action

    func testPipelineAction_RawValues() {
        XCTAssertEqual(Pipeline.Action.dictate.rawValue, "A")
        XCTAssertEqual(Pipeline.Action.translate.rawValue, "B")
        XCTAssertEqual(Pipeline.Action.assist.rawValue, "C")
    }

    func testPipelineAction_InitFromRawValue() {
        XCTAssertEqual(Pipeline.Action(rawValue: "A"), .dictate)
        XCTAssertEqual(Pipeline.Action(rawValue: "B"), .translate)
        XCTAssertEqual(Pipeline.Action(rawValue: "C"), .assist)
        XCTAssertNil(Pipeline.Action(rawValue: "D"))
    }

    // MARK: - Pipeline.Phase

    func testPipelinePhase_Equatable() {
        XCTAssertEqual(Pipeline.Phase.idle, Pipeline.Phase.idle)
        XCTAssertEqual(Pipeline.Phase.recording, Pipeline.Phase.recording)
        XCTAssertEqual(
            Pipeline.Phase.processing(action: .dictate),
            Pipeline.Phase.processing(action: .dictate)
        )
        XCTAssertNotEqual(Pipeline.Phase.idle, Pipeline.Phase.recording)
        XCTAssertNotEqual(
            Pipeline.Phase.processing(action: .dictate),
            Pipeline.Phase.processing(action: .translate)
        )
    }

    // MARK: - NetworkRetry.isRetryableHTTPStatus

    func testIsRetryableHTTPStatus_500() {
        XCTAssertTrue(NetworkRetry.isRetryableHTTPStatus(in: "HTTP 500: Internal Server Error"))
    }

    func testIsRetryableHTTPStatus_502() {
        XCTAssertTrue(NetworkRetry.isRetryableHTTPStatus(in: "HTTP 502: Bad Gateway"))
    }

    func testIsRetryableHTTPStatus_503() {
        XCTAssertTrue(NetworkRetry.isRetryableHTTPStatus(in: "HTTP 503: Service Unavailable"))
    }

    func testIsRetryableHTTPStatus_408() {
        XCTAssertTrue(NetworkRetry.isRetryableHTTPStatus(in: "HTTP 408: Request Timeout"))
    }

    func testIsRetryableHTTPStatus_429() {
        XCTAssertTrue(NetworkRetry.isRetryableHTTPStatus(in: "HTTP 429: Too Many Requests"))
    }

    func testIsRetryableHTTPStatus_401() {
        XCTAssertFalse(NetworkRetry.isRetryableHTTPStatus(in: "HTTP 401: Unauthorized"))
    }

    func testIsRetryableHTTPStatus_403() {
        XCTAssertFalse(NetworkRetry.isRetryableHTTPStatus(in: "HTTP 403: Forbidden"))
    }

    func testIsRetryableHTTPStatus_404() {
        XCTAssertFalse(NetworkRetry.isRetryableHTTPStatus(in: "HTTP 404: Not Found"))
    }

    func testIsRetryableHTTPStatus_200() {
        XCTAssertFalse(NetworkRetry.isRetryableHTTPStatus(in: "HTTP 200: OK"))
    }

    func testIsRetryableHTTPStatus_NoMatch() {
        XCTAssertFalse(NetworkRetry.isRetryableHTTPStatus(in: "Some other error"))
    }

    func testIsRetryableHTTPStatus_EmptyString() {
        XCTAssertFalse(NetworkRetry.isRetryableHTTPStatus(in: ""))
    }

    // MARK: - NetworkRetry.isRetryableError

    func testIsRetryableError_Timeout() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertTrue(NetworkRetry.isRetryableError(error))
    }

    func testIsRetryableError_NoInternet() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertTrue(NetworkRetry.isRetryableError(error))
    }

    func testIsRetryableError_Cancelled() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertFalse(NetworkRetry.isRetryableError(error))
    }

    func testIsRetryableError_BadURL() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL)
        XCTAssertFalse(NetworkRetry.isRetryableError(error))
    }

    func testIsRetryableError_ConnectionLost() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        XCTAssertTrue(NetworkRetry.isRetryableError(error))
    }

    func testIsRetryableError_DNSFailure() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorDNSLookupFailed)
        XCTAssertTrue(NetworkRetry.isRetryableError(error))
    }

    func testIsRetryableError_CannotFindHost() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        XCTAssertTrue(NetworkRetry.isRetryableError(error))
    }

    func testIsRetryableError_NonURLErrorDomain() {
        let error = NSError(domain: "SomeOtherDomain", code: 42)
        XCTAssertFalse(NetworkRetry.isRetryableError(error))
    }
}
