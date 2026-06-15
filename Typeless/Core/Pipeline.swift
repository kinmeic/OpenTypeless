import Foundation
import os.log

private let logger = Logger(subsystem: "com.typeless.app", category: "pipeline")

// MARK: - Pipeline State Machine

/// The core state machine for the three-key workflow:
///   IDLE → (press A/B/C) → RECORDING → (press A/B/C) → PROCESSING → IDLE
///
/// The key pressed on STOP determines which pipeline runs:
///   A = Dictate (speech → text → inject)
///   B = Translate (speech → text → LLM translate → inject)
///   C = Assist (speech → text + context → LLM multimodal → inject)
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

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastError: String? {
        didSet {
            if let error = lastError {
                NotificationManager.shared.showError(title: "Typeless Error", message: error)
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

    private var currentASR: ASREngine?
    private var recordingTask: Task<Void, Never>?
    private var silenceTimer: Timer?
    private var lastVoiceTime: Date?

    init() {
        monitor.update(settings.shortcuts)
        monitor.start { [weak self] event in
            guard let self else { return }
            let action = self.action(from: event)
            self.handleShortcut(action: action)
        }
    }

    deinit {
        // Deinit is nonisolated; we cannot call @MainActor-isolated methods.
        // The monitor's event tap will be cleaned up by the OS when the process exits.
        // For explicit cleanup, use Pipeline.stop() before releasing the reference.
    }

    // MARK: - Public

    func handleShortcut(action: Action) {
        switch phase {
        case .idle:
            recordingTask = Task { await startRecording() }
        case .recording:
            recordingTask?.cancel()
            recordingTask = Task { await stopAndProcess(action: action) }
        case .processing:
            // Ignore while processing
            break
        }
    }

    func stop() {
        monitor.stop()
        recorder.stop()
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

        do {
            // 根据配置创建 ASR 引擎
            currentASR = makeASREngine()
            try currentASR?.start()

            // 开始录音，buffer 喂给 ASR
            try recorder.start(
                inputDeviceID: nil,
                onBuffer: { [weak self] buffer in
                    self?.currentASR?.feed(buffer)
                },
                onLevel: { [weak self] level in
                    Task { @MainActor in
                        self?.handleAudioLevel(level)
                    }
                }
            )

            phase = .recording
            startSilenceDetection()
        } catch {
            logger.error("Failed to start recording: \(error.localizedDescription)")
            lastError = error.localizedDescription
            phase = .idle
            currentASR = nil
        }
    }

    private func stopAndProcess(action: Action) async {
        guard phase == .recording else { return }
        logger.info("Stopping recording, action=\(action.rawValue)")

        // 停止录音和静音检测
        silenceTimer?.invalidate()
        silenceTimer = nil
        recorder.stop()
        inputLevel = 0

        phase = .processing(action: action)

        do {
            // 获取转写结果
            let text = try await currentASR?.finalize() ?? ""
            currentASR = nil
            lastTranscript = text
            logger.info("Transcript: \(text)")

            // 根据动作执行后处理
            switch action {
            case .dictate:
                // A：直接注入转写文字
                await injector.insert(text)

            case .translate:
                // B：翻译后注入
                let translated = try await translate(text)
                await injector.insert(translated)

            case .assist:
                // C：采集上下文 + LLM 处理后注入
                let ctx = await context.collect()
                let answer = try await assist(transcription: text, context: ctx)
                await injector.insert(answer)
            }
        } catch {
            logger.error("Processing failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }

        phase = .idle
    }

    // MARK: - ASR Engine Factory

    private func makeASREngine() -> ASREngine {
        switch settings.asr.engine {
        case .remote:
            if settings.asr.remoteConfigured {
                return RemoteASR(config: settings.asr)
            } else {
                // 远程 ASR 未配置，降级到系统 STT
                logger.warning("Remote ASR not configured, falling back to system speech")
                return SystemSpeechASR(config: settings.asr)
            }
        case .systemSpeech:
            return SystemSpeechASR(config: settings.asr)
        }
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
