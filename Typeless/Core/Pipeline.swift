import Foundation
import CoreAudio
import AppKit
import os.log

private let logger = Logger(subsystem: "com.opentypeless.app", category: "pipeline")

// MARK: - Pipeline State Machine

/// The core state machine for the three-key workflow:
///   IDLE → (press A/B/C) → RECORDING → (press A/B/C) → PROCESSING → IDLE
///
/// The key pressed on STOP determines which pipeline runs:
///   A = Dictate (speech → text → inject)
///   B = Translate (speech → text → LLM translate → inject)
///   C = Assist (speech → text + selected text → LLM → overlay)
///
/// ASR 采用非实时（batch）模式：录完整段音频落盘后，PROCESSING 阶段一次性转写。
@MainActor
final class Pipeline: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case processing(action: Action)
    }

    enum Action: String {
        case dictate = "A"
        case translate = "B"
        case assist = "C"
    }

    typealias TestOutputHandler = @MainActor (String) -> Void

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastError: String? {
        didSet {
            if let error = lastError {
                NotificationManager.shared.showError(title: "OpenTypeless Error", message: error)
            }
        }
    }
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var lastTranscript: String?

    private let monitor = KeyboardMonitor()
    private let recorder = AudioRecorder()
    private let injector = TextInjector()
    private let context = ContextCollector()
    private let llm = LLMClient()
    private let settings = AppSettings.shared
    private let audioMuter = SystemAudioMuter()
    private let soundFeedback = SoundFeedback()

    private var recordingTask: Task<Void, Never>?
    private var silenceTimer: Timer?
    private var lastVoiceTime: Date?

    /// 非实时模式下的临时录音文件 URL，转写完后删除。
    private var recordingFileURL: URL?

    private var terminateObserver: NSObjectProtocol?

    init() {
        monitor.update(settings.shortcuts)
        monitor.start { [weak self] event in
            guard let self else { return }
            let action = self.action(from: event)
            self.handleShortcut(action: action)
        }
        // 监听应用退出，确保静音/录音资源被恢复和释放
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stop()
        }
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
        // Deinit is nonisolated; we cannot call @MainActor-isolated methods。
        // 关键资源（静音恢复）已由 stop() / willTerminate 处理。
    }

    // MARK: - Public

    func handleShortcut(action: Action) {
        handleAction(action: action, testOutput: nil)
    }

    func handleTestAction(action: Action, output: @escaping TestOutputHandler) {
        handleAction(action: action, testOutput: output)
    }

    private func handleAction(action: Action, testOutput: TestOutputHandler?) {
        switch phase {
        case .idle:
            recordingTask = Task { await startRecording() }
        case .recording:
            recordingTask?.cancel()
            recordingTask = Task { await stopAndProcess(action: action, testOutput: testOutput) }
        case .processing:
            // Ignore while processing
            break
        }
    }

    func stop() {
        monitor.stop()
        recorder.stop()
        // 确保静音被恢复（退出/释放时若仍在录音状态）
        audioMuter.restore()
        silenceTimer?.invalidate()
        silenceTimer = nil
        cleanupRecordingFile()
        RecordingOverlay.shared.hide()
        ProcessingOverlay.shared.hide()
    }

    func clearError() {
        lastError = nil
    }

    // MARK: - Phase Transitions

    private func startRecording() async {
        guard phase == .idle else { return }
        logger.info("Starting recording")
        lastError = nil
        lastTranscript = nil
        // 重置上次语音时间戳：否则静音检测会沿用上一段录音的时间戳，
        // 导致本次录音刚启动就被误判为“已静音超时”而提前停止（第二次录音失败的根因）。
        lastVoiceTime = nil

        // 交互声音：开始
        if settings.playInteractionSound { soundFeedback.playStart() }
        // 静音系统输出
        if settings.muteSystemAudioDuringRecording { audioMuter.mute() }

        do {
            // 非实时模式：录音落盘 m4a
            recordingFileURL = makeRecordingFileURL()

            // 解析配置的输入设备 ID（空串或无法解析时用系统默认）
            let deviceID = AudioDeviceID(settings.audioInputDeviceID) ?? 0

            try recorder.start(
                inputDeviceID: deviceID,
                recordToFile: recordingFileURL!,
                onLevel: { [weak self] level in
                    Task { @MainActor in
                        self?.handleAudioLevel(level)
                    }
                }
            )

            phase = .recording
            startSilenceDetection()
            // 显示录音浮层
            RecordingOverlay.shared.show(pipeline: self)
        } catch {
            logger.error("Failed to start recording: \(error.localizedDescription)")
            lastError = error.localizedDescription
            phase = .idle
            cleanupRecordingFile()
            // 启动失败也要恢复静音
            audioMuter.restore()
        }
    }

    private func stopAndProcess(action: Action, testOutput: TestOutputHandler? = nil) async {
        guard phase == .recording else { return }
        logger.info("Stopping recording, action=\(action.rawValue)")

        // 停止录音和静音检测
        silenceTimer?.invalidate()
        silenceTimer = nil
        recorder.stop()
        inputLevel = 0

        // 隐藏录音浮层
        RecordingOverlay.shared.hide()

        // 恢复系统输出 + 交互声音：停止
        audioMuter.restore()
        if settings.playInteractionSound { soundFeedback.playEnd() }

        phase = .processing(action: action)
        ProcessingOverlay.shared.show(pipeline: self)
        defer {
            ProcessingOverlay.shared.hide()
            cleanupRecordingFile()
            phase = .idle
        }

        do {
            // 非实时转写：创建引擎，调 transcribeFile
            let asr = makeASREngine()
            let text: String
            if let url = recordingFileURL {
                text = try await asr.transcribeFile(url)
            } else {
                throw NSError(domain: "OpenTypeless", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "No recording file to transcribe."])
            }
            lastTranscript = text
            logger.info("Transcript: \(text)")

            // 根据动作执行后处理
            switch action {
            case .dictate:
                // A：配置了 Text Model 时先用 LLM 加工（去填充词/重复/结构化），否则直接注入
                let finalText: String
                if textModelConfigured {
                    do {
                        finalText = try await llm.refine(text, using: settings.llm)
                    } catch {
                        logger.warning("Refine failed, using raw transcript: \(error.localizedDescription)")
                        finalText = text
                    }
                } else {
                    finalText = text
                }
                if let testOutput {
                    testOutput(finalText)
                } else {
                    await injector.insert(finalText)
                }

            case .translate:
                // B：翻译后注入
                let translated = try await translate(text)
                if let testOutput {
                    testOutput(translated)
                } else {
                    await injector.insert(translated)
                }

            case .assist:
                // C：采集选中文本（可选）+ LLM 处理，结果以弹窗显示（不注入文本框）
                let ctx = await context.collect()
                let answer = try await assist(transcription: text, context: ctx)
                ResultOverlay.shared.show(answer: answer)
            }
        } catch {
            logger.error("Processing failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    // MARK: - Recording File Helpers

    /// 生成临时录音文件 URL（m4a）。
    private func makeRecordingFileURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("opentypeless-\(UUID().uuidString).m4a")
    }

    /// 删除临时录音文件并清空引用。
    private func cleanupRecordingFile() {
        if let url = recordingFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingFileURL = nil
    }

    // MARK: - Silence Detection (auto-stop after 2s of silence)

    private func startSilenceDetection() {
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                if let lastVoice = self.lastVoiceTime,
                   Date().timeIntervalSince(lastVoice) > 2.0 {
                    // 静音超过 2 秒，自动停止并走 A（直出）
                    logger.info("Auto-stop after 2s silence")
                    self.handleShortcut(action: .dictate)
                }
            }
        }
    }

    private func handleAudioLevel(_ level: Double) {
        inputLevel = level
        // 电平高于阈值视为有语音
        if level > 0.08 {
            lastVoiceTime = Date()
        }
    }

    /// Text Model 是否已配置（apiKey 非空或本地 provider）。
    private var textModelConfigured: Bool {
        let key = settings.llm.textApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = settings.llm.textProvider.lowercased()
        return !key.isEmpty || provider == "ollama" || provider == "lm-studio" || provider == "local"
    }

    // MARK: - ASR Engine Factory

    private func makeASREngine() -> ASREngine {
        switch settings.asr.engine {
        case .llm:
            // ASR Model：用 LLM 配置（智谱 GLM-ASR 等）
            let asrConfigured: Bool
            if settings.llm.asrProviderSameAsText || settings.llm.asrProvider == "same" {
                asrConfigured = !settings.llm.textApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } else {
                asrConfigured = !settings.llm.asrApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if asrConfigured {
                return LLMASR(config: settings.llm)
            } else {
                logger.warning("ASR Model not configured, falling back to system speech")
                return SystemSpeechASR(config: settings.asr)
            }
        case .systemSpeech:
            return SystemSpeechASR(config: settings.asr)
        }
    }

    // MARK: - LLM Operations

    private func translate(_ text: String) async throws -> String {
        try await llm.translate(text, to: settings.targetLanguage, using: settings.llm)
    }

    private func assist(transcription: String, context: ContextCollector.CollectedContext) async throws -> String {
        try await llm.assist(transcription: transcription, context: context, using: settings.llm)
    }

    // MARK: - Helpers

    private func action(from event: ShortcutEvent) -> Action {
        let configs = [settings.shortcuts.a, settings.shortcuts.b, settings.shortcuts.c]
        let matched = configs.first {
            $0.keyCode == event.keyCode && $0.modifierFlags == Int(event.modifiers.rawValue)
        }
        return Action(rawValue: matched?.role ?? "A") ?? .dictate
    }
}
