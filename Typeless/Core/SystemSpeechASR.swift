import Foundation
import AVFAudio
import Speech
import os.log

private let logger = Logger(subsystem: "com.typeless.app", category: "asr-system")

/// 系统语音识别引擎（非实时 batch 模式）。
///
/// 特性：
/// - 多语言串行识别（对每个配置语言各跑一次 `SFSpeechURLRecognitionRequest`，取最长结果）
/// - 强制 on-device 识别（不上传 Apple 云端，保护隐私）
/// - 自动加标点（macOS 14+）
///
/// 注意：系统 Speech URL 识别单任务限制约 1 分钟，Typeless 短句场景足够。
final class SystemSpeechASR: ASREngine {
    enum ASError: LocalizedError {
        case notAuthorized
        case recognizerUnavailable
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Speech Recognition is not authorized."
            case .recognizerUnavailable:
                return "No on-device speech recognizer available for the configured languages."
            case .emptyResult:
                return "No speech text was recognized."
            }
        }
    }

    private let queue = DispatchQueue(label: "Typeless.SystemSpeechASR")

    private let config: ASRConfig

    init(config: ASRConfig) {
        self.config = config
    }

    // MARK: - Batch (non-realtime) transcription

    /// 非实时转写：对整段音频文件做一次性识别。
    /// 对每个配置语言各跑一次 `SFSpeechURLRecognitionRequest`，取最长结果。
    func transcribeFile(_ url: URL) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw ASError.notAuthorized
        }

        let recognizers = config.languageIDs.compactMap { languageID -> (String, SFSpeechRecognizer)? in
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageID)),
                  recognizer.isAvailable else {
                logger.warning("Recognizer for \(languageID) unavailable")
                return nil
            }
            return (languageID, recognizer)
        }
        guard recognizers.isEmpty == false else {
            throw ASError.recognizerUnavailable
        }

        // 串行跑各语言，取最长结果（准确率优先于并行速度）
        var best: (language: String, text: String) = ("", "")
        for (languageID, recognizer) in recognizers {
            let text = await transcribe(url: url, with: recognizer, languageID: languageID)
            logger.info("SystemSpeechASR [\(languageID)]: \(text.count) chars")
            if text.count > best.text.count {
                best = (languageID, text)
            }
        }

        let trimmed = best.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw ASError.emptyResult
        }
        logger.info("SystemSpeechASR result: \(trimmed.count) chars [\(best.language)]")
        return trimmed
    }

    /// 对单个语言跑文件识别，返回完整转写文字。
    /// 使用 hasResumed flag 防止 double-resume，并在回调未提供 final/error 时
    /// （如 recognizer 直接结束）也 resume，避免 Task 永久挂起。
    private func transcribe(url: URL, with recognizer: SFSpeechRecognizer, languageID: String) async -> String {
        await withCheckedContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            if #available(macOS 14.0, *) {
                request.addsPunctuation = true
            }

            // 用原子 flag 防止 double-resume（continuation 只能 resume 一次）
            let hasResumed = NSLock()
            var resumed = false
            let resumeOnce: (String) -> Void = { value in
                hasResumed.lock()
                let shouldResume = !resumed
                resumed = true
                hasResumed.unlock()
                if shouldResume {
                    continuation.resume(returning: value)
                }
            }

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    logger.warning("File recognition [\(languageID)] error: \(error.localizedDescription)")
                    resumeOnce("")
                    return
                }
                if let result {
                    if result.isFinal {
                        let text = result.bestTranscription.formattedString
                        resumeOnce(text)
                    }
                    // 非 final：忽略，等最终结果
                } else {
                    // 无 result 无 error（recognizer 异常结束）：resume 空串避免挂起
                    resumeOnce("")
                }
            }

            // 兜底：如果 recognizer 因系统限制（如 ~1 分钟单任务上限）迟迟不回调，
            // 30 秒后强制 resume，防止 Task 永久挂起。
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                resumeOnce("")
                task.cancel()  // 取消任务（若仍在跑）
            }
        }
    }
}
