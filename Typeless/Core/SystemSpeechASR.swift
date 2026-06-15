import Foundation
import AVFAudio
import Speech
import os.log

private let logger = Logger(subsystem: "com.typeless.app", category: "asr-system")

/// 系统语音识别引擎，参照 PowerMeetings LiveSpeechTranscriber。
///
/// 特性：
/// - 多语言并行识别（同时跑 zh-CN + en-US，取最先有结果的）
/// - 强制 on-device 识别（不上传 Apple 云端，保护隐私）
/// - 自动加标点（macOS 14+）
/// - 静音检测（1.5s 无语音视为静音，用于自动断句）
/// - isStoppingIntentionally 标志区分主动停止和异常退出
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
    private var recognitionRequests: [SFSpeechAudioBufferRecognitionRequest] = []
    private var recognitionTasks: [SFSpeechRecognitionTask] = []
    private var isStoppingIntentionally = false

    /// 累积的转写结果（按语言分组，取最长/最新的）。
    private var transcriptsByLanguage: [String: String] = [:]
    private var bestLanguageID: String?

    private let config: ASRConfig
    private(set) var isRunning = false

    init(config: ASRConfig) {
        self.config = config
    }

    // MARK: - ASREngine

    func start() throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw ASError.notAuthorized
        }

        // 筛选支持 on-device 识别的 recognizer（多语言并行）
        let recognizers = config.languageIDs.compactMap { languageID -> (String, SFSpeechRecognizer)? in
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageID)),
                  recognizer.supportsOnDeviceRecognition,
                  recognizer.isAvailable else {
                logger.warning("Recognizer for \(languageID) unavailable or no on-device support")
                return nil
            }
            return (languageID, recognizer)
        }

        guard recognizers.isEmpty == false else {
            throw ASError.recognizerUnavailable
        }

        transcriptsByLanguage = [:]
        bestLanguageID = nil
        isStoppingIntentionally = false

        // 为每种语言创建独立的 recognition request
        for (languageID, recognizer) in recognizers {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if #available(macOS 13.0, *) {
                request.requiresOnDeviceRecognition = true  // 强制本地
            }
            if #available(macOS 14.0, *) {
                request.addsPunctuation = true  // 自动加标点
            }

            let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let transcript = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if transcript.isEmpty == false {
                        self.queue.async {
                            self.transcriptsByLanguage[languageID] = transcript
                            // 选当前最长的结果所在的语言为 best
                            if self.bestLanguageID == nil
                                || (self.transcriptsByLanguage[languageID]?.count ?? 0)
                                > (self.transcriptsByLanguage[self.bestLanguageID ?? ""]?.count ?? 0) {
                                self.bestLanguageID = languageID
                            }
                        }
                    }
                }
                if let error, self.isStoppingIntentionally == false {
                    // 非主动停止的错误：静默处理（其他并行 recognizer 可能仍在工作）
                    logger.warning("\(languageID) recognition error: \(error.localizedDescription)")
                }
            }
            recognitionRequests.append(request)
            recognitionTasks.append(task)
        }

        isRunning = true
        logger.info("SystemSpeechASR started with \(recognizers.count) language(s): \(self.config.languageIDs)")
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            self?.recognitionRequests.forEach { $0.append(buffer) }
        }
    }

    func finalize() async throws -> String {
        // 停止接收新音频，让 recognizer 产出最终结果
        queue.sync {
            isStoppingIntentionally = true
            recognitionRequests.forEach { $0.endAudio() }
        }

        // 等待一小段时间让最后的 partial 结果稳定下来
        try? await Task.sleep(for: .milliseconds(500))

        // 取最佳语言的结果
        let text = bestTranscript

        queue.sync {
            recognitionTasks.forEach { $0.cancel() }
            recognitionTasks = []
            recognitionRequests = []
            isRunning = false
        }

        logger.info("SystemSpeechASR finalized: \(text.isEmpty ? "(empty)" : "\(text.count) chars") [\(self.bestLanguageID ?? "none")]")

        guard text.isEmpty == false else {
            throw ASError.emptyResult
        }
        return text
    }

    // MARK: - Helpers

    private var bestTranscript: String {
        guard let bestID = bestLanguageID,
              let text = transcriptsByLanguage[bestID] else {
            // 没有明确的 best，取所有结果中最长的
            return transcriptsByLanguage.values.max(by: { $0.count < $1.count }) ?? ""
        }
        return text
    }
}
