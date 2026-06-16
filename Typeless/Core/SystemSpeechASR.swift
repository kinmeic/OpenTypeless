import Foundation
import AVFAudio
import Speech
import os.log

private let logger = Logger(subsystem: "com.opentypeless.app", category: "asr-system")

/// 系统语音识别引擎（非实时 batch 模式）。
///
/// 特性：
/// - 使用设置里选择的单一识别语言，避免不同 locale 之间互相误判
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
                return "No speech recognizer is available for the configured language."
            case .emptyResult:
                return "No speech text was recognized."
            }
        }
    }

    private let config: ASRConfig
    /// 复用同一个 SFSpeechRecognizer 实例，避免短时间内连续创建新 recognizer 导致 task 失败。
    private var sharedRecognizer: SFSpeechRecognizer?
    /// 跟踪当前/上一个 recognition task，用于在启动新 task 前取消旧 task，避免资源冲突。
    private var previousRecognitionTask: SFSpeechRecognitionTask?

    init(config: ASRConfig) {
        self.config = config
    }

    // MARK: - Batch (non-realtime) transcription

    /// 非实时转写：对整段音频文件做一次性识别。
    /// 使用设置里选择的 `recognitionLanguageID` 创建对应 locale 的识别器。
    func transcribeFile(_ url: URL) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw ASError.notAuthorized
        }

        let languageID = config.recognitionLanguageID
        
        // 复用或创建 recognizer：同一个 locale 的 recognizer 实例可复用，
        // 避免短时间内连续 new 实例导致底层 task 资源冲突。
        let recognizer: SFSpeechRecognizer
        if let existing = sharedRecognizer, existing.locale.identifier == languageID {
            recognizer = existing
        } else {
            guard let newRecognizer = SFSpeechRecognizer(locale: Locale(identifier: languageID)),
                  newRecognizer.isAvailable else {
                logger.warning("Recognizer for \(languageID) unavailable")
                throw ASError.recognizerUnavailable
            }
            sharedRecognizer = newRecognizer
            recognizer = newRecognizer
        }

        let text = await transcribe(url: url, with: recognizer, languageID: languageID)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw ASError.emptyResult
        }
        logger.info("SystemSpeechASR result: \(trimmed.count) chars [\(languageID)]")
        return trimmed
    }

    /// 对单个语言跑文件识别，返回完整转写文字。
    /// 使用 hasResumed flag 防止 double-resume，并在回调未提供 final/error 时
    /// （如 recognizer 直接结束）也 resume，避免 Task 永久挂起。
    private func transcribe(url: URL, with recognizer: SFSpeechRecognizer, languageID: String) async -> String {
        // 取消前一个可能还在运行的 task，避免资源冲突
        if let previousTask = previousRecognitionTask {
            previousTask.cancel()
        }
        
        return await withCheckedContinuation { continuation in
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

            let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let error {
                    logger.warning("File recognition [\(languageID)] error: \(error.localizedDescription)")
                    self?.previousRecognitionTask = nil
                    resumeOnce("")
                    return
                }
                if let result {
                    if result.isFinal {
                        let text = result.bestTranscription.formattedString
                        self?.previousRecognitionTask = nil
                        resumeOnce(text)
                    }
                    // 非 final：忽略，等最终结果
                } else {
                    // 无 result 无 error（recognizer 异常结束）：resume 空串避免挂起
                    self?.previousRecognitionTask = nil
                    resumeOnce("")
                }
            }
            
            self.previousRecognitionTask = task

            // 兜底：如果 recognizer 因系统限制（如 ~1 分钟单任务上限）迟迟不回调，
            // 75 秒后强制取消并 resume，防止 Task 永久挂起，同时给系统 URL 识别约 1 分钟的任务上限留余量。
            DispatchQueue.global().asyncAfter(deadline: .now() + 75) { [weak self] in
                self?.previousRecognitionTask?.cancel()
                resumeOnce("")
                self?.previousRecognitionTask = nil
            }
        }
    }
}
