import Foundation
import AVFAudio
import os.log

private let logger = Logger(subsystem: "com.typeless.app", category: "asr-remote")

/// 大模型实时 ASR（WebSocket 流式）。
/// 参照 PowerMeetings AliyunParaformerTranscriber。
///
/// 特性：
/// - WebSocket 双工：先发 run-task 指令，等 task-started 后发音频
/// - pendingAudioChunks 缓冲早期音频，不丢开头
/// - AVAudioConverter 将浮点 PCM 转为 Int16 PCM
/// - 厂商协议通过 provider 字段区分（目前内置阿里 Paraformer）
final class RemoteASR: ASREngine {
    enum ASError: LocalizedError {
        case notConfigured
        case connectionFailed(String)
        case taskFailed(String)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Remote ASR is not configured. Set API key in settings."
            case .connectionFailed(let message):
                return "Remote ASR connection failed: \(message)"
            case .taskFailed(let message):
                return "Remote ASR task failed: \(message)"
            case .emptyResult:
                return "No speech text was recognized."
            }
        }
    }

    private let queue = DispatchQueue(label: "Typeless.RemoteASR")
    private let urlSession = URLSession(configuration: .default)
    private var webSocketTask: URLSessionWebSocketTask?

    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var taskID = UUID().uuidString
    private var isTaskStarted = false
    private var pendingAudioChunks: [Data] = []
    private var isStoppingIntentionally = false

    /// 累积的转写结果。
    private var accumulatedText = ""

    private let config: ASRConfig
    private(set) var isRunning = false

    init(config: ASRConfig) {
        self.config = config
    }

    // MARK: - ASREngine

    func start() throws {
        let apiKey = config.remoteApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey.isEmpty == false else {
            throw ASError.notConfigured
        }

        accumulatedText = ""
        taskID = UUID().uuidString
        isTaskStarted = false
        isStoppingIntentionally = false
        pendingAudioChunks = []

        // 1. 建立 WebSocket 连接
        guard let url = URL(string: config.remoteEndpoint) else {
            throw ASError.connectionFailed("Invalid endpoint URL")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Typeless/0.1.0", forHTTPHeaderField: "user-agent")

        let socket = urlSession.webSocketTask(with: request)
        webSocketTask = socket
        socket.resume()
        logger.info("RemoteASR connecting to \(self.config.remoteEndpoint)")

        // 2. 接收循环
        receiveLoop()

        // 3. 发送 run-task 指令
        sendRunTask()

        // 4. 准备音频格式转换
        try prepareAudioConversion()

        isRunning = true
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let data = self.convertToTargetFormat(buffer) else { return }
            if self.isTaskStarted {
                self.webSocketTask?.send(.data(data)) { _ in }
            } else {
                self.pendingAudioChunks.append(data)
            }
        }
    }

    func finalize() async throws -> String {
        // 发送 finish-task 指令
        queue.sync {
            isStoppingIntentionally = true
            sendFinishTask()
        }

        // 等待服务器返回最终结果
        try? await Task.sleep(for: .milliseconds(800))

        queue.sync {
            webSocketTask?.cancel(with: .normalClosure, reason: nil)
            webSocketTask = nil
            converter = nil
            outputFormat = nil
            pendingAudioChunks = []
            isTaskStarted = false
            isRunning = false
        }

        logger.info("RemoteASR finalized: \(self.accumulatedText.isEmpty ? "(empty)" : "\(self.accumulatedText.count) chars")")

        let text = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else {
            throw ASError.emptyResult
        }
        return text
    }

    // MARK: - Audio Format Conversion

    private func prepareAudioConversion() throws {
        // 目标格式：Int16 PCM，单声道，配置的采样率
        let sampleRate = Double(config.remoteSampleRate)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw ASError.connectionFailed("Could not create target audio format")
        }

        // 输入格式由 AVAudioEngine 的实际 buffer 决定，转换器在 feed 时懒创建
        // 这里先存目标格式，第一个 buffer 到来时用其源格式创建 converter
        outputFormat = targetFormat
    }

    /// 将浮点 PCM buffer 转换为目标 Int16 PCM Data。
    /// 参照 PowerMeetings convertToPCM8k。
    private func convertToTargetFormat(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let outputFormat else { return nil }

        // 懒创建 converter（第一次需要源格式）
        if converter == nil {
            guard let conv = AVAudioConverter(from: buffer.format, to: outputFormat) else {
                logger.error("Could not create AVAudioConverter")
                return nil
            }
            converter = conv
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            return nil
        }

        var didProvideInput = false
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, status in
            if didProvideInput {
                status.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil,
              let data = outputBuffer.int16ChannelData,
              outputBuffer.frameLength > 0 else { return nil }
        return Data(bytes: data[0], count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size)
    }

    // MARK: - WebSocket Protocol

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receiveLoop()
                case .failure(let error):
                    if self.isStoppingIntentionally == false {
                        logger.error("WebSocket receive failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text):
            data = text.data(using: .utf8)
        case .data(let messageData):
            data = messageData
        @unknown default:
            data = nil
        }

        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = object["header"] as? [String: Any],
              let event = header["event"] as? String else { return }

        switch event {
        case "task-started":
            isTaskStarted = true
            logger.info("ASR task started, flushing \(self.pendingAudioChunks.count) pending chunks")
            // 发送缓冲的早期音频
            for chunk in pendingAudioChunks {
                webSocketTask?.send(.data(chunk)) { _ in }
            }
            pendingAudioChunks = []

        case "result-generated":
            guard let payload = object["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any],
                  (sentence["heartbeat"] as? Bool) != true,
                  let text = sentence["text"] as? String else { return }
            let isFinal = sentence["sentence_end"] as? Bool ?? false
            if isFinal {
                // 句子结束，追加到累积结果
                accumulatedText += text
                logger.info("ASR final segment: \(text)")
            } else {
                // 部分结果，替换最后一段（实时修正）
                // 简化处理：如果是句子结束就追加，否则保留最新 partial
                if accumulatedText.isEmpty {
                    accumulatedText = text
                }
            }

        case "task-failed":
            let message = header["error_message"] as? String ?? "Unknown task failure"
            logger.error("ASR task failed: \(message)")
            isStoppingIntentionally = true

        case "task-finished":
            logger.info("ASR task finished")

        default:
            break
        }
    }

    private func sendRunTask() {
        let model = config.remoteModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let sampleRate = config.remoteSampleRate

        let parameters: [String: Any] = [
            "format": "pcm",
            "sample_rate": sampleRate,
            "disfluency_removal_enabled": false,
            "semantic_punctuation_enabled": false,
            "punctuation_prediction_enabled": true,
            "max_sentence_silence": 1500,
            "heartbeat": true
        ]

        let message: [String: Any] = [
            "header": [
                "action": "run-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": model,
                "parameters": parameters,
                "input": [:]
            ]
        ]
        sendJSON(message)
    }

    private func sendFinishTask() {
        let message: [String: Any] = [
            "header": [
                "action": "finish-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": ["input": [:]]
        ]
        sendJSON(message)
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { _ in }
    }
}
