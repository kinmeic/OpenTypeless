# Typeless（Swift 原生版）技术设计

> 基于 PTerminal 的 AI 配置抽象、CD-Switch 的菜单栏骨架、Typeless 设计文档的领域逻辑（KeyboardHelper / InputHelper 的状态机与注入降级链）、**PowerMeetings 的 ASR 实战经验**（系统 Speech 多语言并行 + 阿里 Paraformer WebSocket 流式 + 音频降噪与格式转换），用 **纯 Swift + SwiftUI** 重新落地。

---

## 0. 目标与范围

一个 macOS **菜单栏（menu bar）App**，通过全局快捷键触发语音转写，并把结果**注入到当前焦点文本框**。

| 需求 | 对应模块 |
|---|---|
| 1. 配置文字模型 + 多模态模型 | `LLMClient` + 设置面板 |
| 2. 语音转文字（系统 STT 或大模型 ASR） | `AudioRecorder` + `ASREngine` |
| 3. 全局组合键 A/B/C 触发录音/转写/翻译/LLM 处理并注入 | `KeyboardMonitor` + `Pipeline` + `TextInjector` |
| 4. 菜单栏图标：设置 / 选择音频输入源 / 退出 | `MenuBarExtra`（参照 CD-Switch） |

**非目标**：跨平台、复杂 UI、云端同步。

---

## 1. 技术栈与版本基线

| 项 | 版本 | 备注 |
|---|---|---|
| macOS 部署目标 | **14.0 (Sonoma)** | `MenuBarExtra` 需 13+；`Speech` 现代 API 需 14+。当前开发机 26.5 |
| Xcode / Swift | 26.2 / 6.2.3 | async/await、Observation 框架可用 |
| UI | SwiftUI | `MenuBarExtra` + `Window`（设置窗口） |
| 音频 | AVFAudio（`AVAudioEngine`） | 实时采集 + 写文件 |
| 语音识别 | Speech（`SFSpeechRecognizer`） | 系统内置 STT，**参照 PowerMeetings 做多语言并行 + on-device + 静音检测** |
| 全局键监听 | CoreGraphics（`CGEventTap`） | 需 Input Monitoring 权限 |
| 文本注入 | ApplicationServices（`AXUIElement`）+ CoreGraphics（模拟 ⌘V） | 需 Accessibility 权限 |
| HTTP | `URLSession` async | 不引入第三方 |
| 持久化 | `UserDefaults` + `Codable` | 配置项少，够用；后续可换 SwiftData |
| App 形态 | `LSUIElement = true`（accessory） | 不进 Dock，只在菜单栏（参照 CD-Switch `Info.plist`） |

**零第三方依赖**（除可选的 Sparkle 做自动更新）。这是相比 PTerminal(Tauri) 和 Typeless(Electron+koffi) 的最大简化。

---

## 2. 工程结构

Xcode App project（**不是** Swift Package），因为 `MenuBarExtra` + entitlements + Info.plist + 系统签名都需要 App target。核心逻辑用文件夹分层，便于测试。

```
Typeless/
├── Typeless.xcodeproj
├── Typeless/
│   ├── App/
│   │   ├── TypelessApp.swift          # @main, MenuBarExtra + Window，参照 CD-Switch ClaudeSwitchApp.swift
│   │   ├── AppDelegate.swift          # setActivationPolicy(.accessory), 权限引导
│   │   └── AppSettings.swift          # 单例配置（UserDefaults + Codable），参照 CD-Switch AppState
│   ├── Info.plist                     # LSUIElement=true + usage descriptions
│   ├── Typeless.entitlements          # 麦克风/语音识别/沙盒开关
│   │
│   ├── Core/
│   │   ├── KeyboardMonitor.swift      # CGEventTap 全局监听 + 快捷键匹配（领域逻辑同 Typeless KeyboardHelper）
│   │   ├── ShortcutDetector.swift     # keyCode↔name 映射 + 组合匹配
│   │   ├── AudioRecorder.swift        # AVAudioEngine 采集，参照 PowerMeetings 降噪 + 格式转换
│   │   ├── ASREngine.swift            # 系统 Speech / 大模型 ASR 两种实现（参照 PowerMeetings 双引擎架构）
│   │   ├── TextInjector.swift         # AX 直写 → 剪贴板+⌘V 降级链（同 Typeless InputHelper）
│   │   ├── ContextCollector.swift     # 选中文本 / 剪贴板图片+文字（C 流程上下文）
│   │   ├── LLMClient.swift            # OpenAI / Anthropic 双协议（移植 PTerminal ai/）
│   │   ├── Pipeline.swift             # 三键状态机 + 后处理流水线编排
│   │   └── Permissions.swift          # 权限状态检测 + 引导打开系统设置面板
│   │
│   ├── Models/
│   │   ├── Config.swift               # ProviderConfig / ASRConfig / ShortcutConfig 等 Codable
│   │   └── Events.swift               # KeyEvent / ShortcutEvent / PipelinePhase
│   │
│   ├── Views/                         # 参照 CD-Switch Views/ 结构
│   │   ├── MenuBarMenu.swift          # 菜单栏下拉菜单
│   │   ├── SettingsWindow.swift       # 设置主窗口（TabView）
│   │   ├── SettingsGeneralTab.swift   # 音频源选择 / 主题 / 开机启动
│   │   ├── SettingsLLMTab.swift       # 文字模型 + 多模态模型配置（移植 PTerminal SettingsPage）
│   │   ├── SettingsASRTab.swift       # STT 来源切换 + 目标翻译语言
│   │   ├── SettingsShortcutsTab.swift # A/B/C 三个快捷键录制
│   │   └── AudioDevicePicker.swift    # 选择音频输入源
│   │
│   └── Support/
│       ├── KeyCodes.swift             # macOS virtual key codes 映射（Typeless Utils.swift）
│       └── Logger.swift               # os.log 封装
│
└── TypelessTests/
    ├── ShortcutDetectorTests.swift
    └── PipelineStateTests.swift
```

---

## 3. 架构总览

```
┌─────────────────────────────────────────────────────────────────┐
│                    菜单栏 App (LSUIElement)                       │
│                                                                  │
│   MenuBarExtra ──► MenuBarMenu (设置/音频源/退出)                  │
│        │                                                         │
│        ▼                                                         │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  Pipeline (状态机)                                        │   │
│   │  IDLE ──按A/B/C──► RECORDING ──按A/B/C──► PROCESSING      │   │
│   │                                          │                 │   │
│   └─────┬───────────────────┬────────────────┬────────────────┘   │
│         ▼                   ▼                ▼                    │
│   KeyboardMonitor      AudioRecorder      ASREngine              │
│   (CGEventTap)         (AVAudioEngine)    (Speech/Whisper)       │
│         │                   │                │                    │
│         │                   └──── buff ──────┘                   │
│         ▼                                                      │
│   按键匹配 → 触发 Pipeline                                      │
│                                                                │
│   PROCESSING 分支：                                             │
│     A → ASR 文字 ─────────────────────► TextInjector ──► 焦点框 │
│     B → ASR 文字 → LLM 翻译 ───────────► TextInjector ──► 焦点框 │
│     C → ASR 文字 → ContextCollector ──► LLM(多模态) ► TextInjector│
│                                                                │
│   配置层：AppSettings (UserDefaults) ◄── 设置窗口               │
└─────────────────────────────────────────────────────────────────┘
```

**数据流**：快捷键事件 → Pipeline 状态机调度 → 录音/识别 → （可选翻译/LLM）→ 文本注入。所有跨模块通信走 `AsyncStream` / `AsyncChannel`（Swift concurrency），不引入 Combine（CD-Switch 用了 Combine，但 Swift 6 时代 async/await 更顺）。

---

## 4. 核心模块设计

### 4.1 三键状态机（Pipeline）⚠️ 关键解读

**解读**：A/B/C 是三个**各自独立的快捷键**（可配置为组合键，如 `⌥A` / `⌥B` / `⌥C`）。同一时刻全局只有一个录音会话。**"停止时按下的键"决定走哪条后处理流水线**——这是最符合直觉的语义：用户最后按的就是他想要的动作。

```
状态：IDLE ──────────────► RECORDING ──────────────► PROCESSING ─► IDLE
        按任一快捷键          按任一快捷键              完成/出错
        (开始录音)            (停止录音，记录 action)    (注入完成)
```

- `IDLE` 按下键 X（X ∈ {A,B,C}）→ 开始录音，进入 `RECORDING`，UI 显示录音中。
- `RECORDING` 按下键 Y（Y ∈ {A,B,C}）→ 停止录音，`action = Y`，进入 `PROCESSING`：
  - Y=A：ASR → 文字 → 注入
  - Y=B：ASR → 文字 → LLM 翻译成目标语言 → 注入
  - Y=C：ASR → 文字 → ContextCollector(选中文本/剪贴板图片/剪贴板文字) → LLM 多模态处理 → 注入
- `PROCESSING` 完成或出错 → 回 `IDLE`。
- **错误兜底**：PROCESSING 任一环节失败，用 NSAlert/菜单栏图标提示，不破坏 IDLE 复位。

> 边界：`RECORDING` 中若超时（如 60s）自动停止并走 A（直出）。避免用户忘按第二下。

```swift
@MainActor
final class Pipeline: ObservableObject {
    enum Phase: Equatable { case idle, recording, processing(action: Action) }
    enum Action: String { case dictate = "A", translate = "B", assist = "C" }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastError: String?

    private let monitor: KeyboardMonitor
    private let recorder: AudioRecorder
    private let asr: ASREngine
    private let llm: LLMClient
    private let injector: TextInjector
    private let context: ContextCollector
    private let settings: AppSettings

    func handleShortcut(_ s: ShortcutConfig) {
        switch phase {
        case .idle:
            Task { await startRecording() }
        case .recording:
            let action = Action(rawValue: s.role) ?? .dictate
            Task { await stopAndProcess(action: action) }
        case .processing:
            return  // 处理中忽略
        }
    }
    // startRecording / stopAndProcess 见 §4.7
}
```

### 4.2 KeyboardMonitor（CGEventTap）

领域逻辑照搬 Typeless 的 `Monitor` + `ShortcutDetector`，但用 Swift 原生实现（无需 `@_cdecl`/FFI）。

```swift
import CoreGraphics

final class KeyboardMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// 启动全局键盘监听。callback 在主 run loop 上回调。
    func start(onShortcut: @escaping (ShortcutEvent) -> Void) {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        // info 透传 self 指针
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,          // 只监听不吞事件（避免影响系统）
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<KeyboardMonitor>.fromOpaque(info).takeUnretainedValue()
                me.handle(type: type, event: event, onShortcut: onShortcut)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap else {
            // tapCreate 返回 nil = 未授权 Input Monitoring，上层引导用户去授权
            return
        }
        self.eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        eventTap = nil
    }
}
```

**与 Typeless 的差异**：
- Typeless 用 `.defaultTap`（可吞事件）+ koffi 回调到 JS。这里用 `.listenOnly` —— 因为我们不是要拦截按键，只是要**检测到组合键**然后触发录音。不吞事件对系统更友好，也降低权限敏感度。
- 不需要 `processEvents` / `setWatcherInterval` 那套 NSTimer 轮询 —— CGEventTap 本身就是事件驱动的回调，直接在 callback 里处理。Typeless 那套 timer 是给 FFI 异步边界用的，Swift 原生不需要。
- `ShortcutDetector` 的匹配逻辑（修饰键掩码 + 主键 keyCode）可直接移植，参考 Typeless `Utils.swift` 的 keyCode↔name 双向映射表。

**关键坑（来自 Typeless 文档 §4）**：`CGEvent.tapCreate` 返回 `nil` 即未授权 Input Monitoring。必须在启动时检测，nil 则弹引导。

### 4.3 AudioRecorder（AVAudioEngine）

参照 PowerMeetings 的 `NoiseSuppressingMicrophoneRecorder` 实现：高通滤波 + 软噪声门 + 音频电平检测。

```swift
import AVFAudio

final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let highPass = AVAudioUnitEQ(numberOfBands: 1)
    private var isRecording = false
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var onLevel: ((Double) -> Void)?

    /// 开始录音：同时 (a) 把 buffer 喂给 ASR 的流式识别，(b) 检测音频电平用于 UI 反馈。
    func start(
        inputDevice: AudioDeviceID?,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping (Double) -> Void
    ) throws {
        configureProcessingChain()
        
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioError.noInputFormat
        }
        
        engine.attach(highPass)
        engine.connect(inputNode, to: highPass, format: inputFormat)
        engine.connect(highPass, to: engine.mainMixerNode, format: inputFormat)
        engine.mainMixerNode.outputVolume = 0
        
        highPass.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.applySoftNoiseGate(to: buffer)
            let level = AudioMeterCalculator.audioLevel(from: buffer)
            onLevel(level)
            onBuffer(buffer)   // 喂 ASR
        }
        
        // 选择指定输入设备（需求 4 的"选择音频输入源"）
        if let device = inputDevice { try setInputDevice(device) }
        
        engine.prepare()
        try engine.start()
        isRecording = true
    }
    
    func stop() {
        highPass.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        isRecording = false
    }
    
    private func configureProcessingChain() {
        if let band = highPass.bands.first {
            band.filterType = .highPass
            band.frequency = 85   // 滤除低频环境噪声
            band.bypass = false
        }
    }
    
    /// 软噪声门：低于 noiseFloor 大幅衰减，speechFloor 以上全通，中间线性过渡
    private func applySoftNoiseGate(to buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let noiseFloor: Float = 0.012
        let speechFloor: Float = 0.05
        
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let value = samples[frame]
                let magnitude = abs(value)
                if magnitude < noiseFloor {
                    samples[frame] = value * 0.18
                } else if magnitude < speechFloor {
                    let blend = (magnitude - noiseFloor) / (speechFloor - noiseFloor)
                    samples[frame] = value * (0.18 + 0.82 * blend)
                }
            }
        }
    }
}

// 音频电平计算（RMS → 归一化 0~1）
enum AudioMeterCalculator {
    static func audioLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        var totalSquares = 0.0
        var sampleCount = 0
        
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = Double(samples[frame])
                totalSquares += sample * sample
            }
            sampleCount += frameLength
        }
        
        guard sampleCount > 0 else { return 0 }
        return normalizedMeterLevel(rms: sqrt(totalSquares / Double(sampleCount))) ?? 0
    }
    
    static func normalizedMeterLevel(rms: Double) -> Double? {
        guard rms.isFinite else { return nil }
        return min(1, max(0.03, pow(rms * 12, 0.65)))
    }
}
```

**关键设计（来自 PowerMeetings）**：
- **高通滤波**（85Hz）：滤除空调、风扇等低频环境噪声。
- **软噪声门**：不是硬切，而是三段式（大幅衰减 → 线性过渡 → 全通），避免语音开头被截断。
- **音频电平检测**：RMS 计算 → 归一化到 0~1，用于菜单栏图标动画或录音状态提示。
- **不需要写文件**：Typeless 是"说完即注入"的短语音场景（几秒到几十秒），buffer 直接喂 ASR，无需落盘。PowerMeetings 需要落盘是因为要保存会议录音。

### 4.4 ASREngine（系统 Speech vs 大模型，双引擎架构）⚠️ 参照 PowerMeetings

PowerMeetings 的 ASR 架构非常成熟：**系统 STT 作为默认路径，大模型 ASR 作为可选项，两者自动降级**。Typeless 直接移植这个双引擎模式。

#### 4.4.1 系统 STT（`LiveSpeechTranscriber`）— 默认路径

```swift
import Speech

/// 系统 Speech 实时转写。
/// 参照 PowerMeetings LiveSpeechTranscriber：多语言并行、on-device、静音检测、自动标点。
final class SystemSpeechASR: ASREngine {
    private let queue = DispatchQueue(label: "Typeless.SystemSpeechASR")
    private var audioEngine: AVAudioEngine?
    private var recognitionRequests: [SFSpeechAudioBufferRecognitionRequest] = []
    private var recognitionTasks: [SFSpeechRecognitionTask] = []
    private var isStoppingIntentionally = false
    
    /// 开始流式识别。
    /// - languageIDs: 支持的语言列表，如 ["zh-CN", "en-US"]。多语言并行识别，取最先有结果的。
    /// - onTranscript: (text, languageID, isFinal) -> Void
    /// - onSilence: 检测到 1.5s 静音时回调，可用于自动断句
    func start(
        languageIDs: [String],
        onTranscript: @escaping @Sendable (String, String, Bool) -> Void,
        onSilence: @escaping @Sendable () -> Void
    ) {
        queue.async { [weak self] in
            self?.startOnQueue(languageIDs: languageIDs, onTranscript: onTranscript, onSilence: onSilence)
        }
    }
    
    func feed(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            self?.recognitionRequests.forEach { $0.append(buffer) }
        }
    }
    
    func stop() -> String? {
        queue.sync { [weak self] in
            self?.stopOnQueue()
        }
        // 返回最后一次转写结果（由 onTranscript 回调累积）
        return nil
    }
    
    private func startOnQueue(
        languageIDs: [String],
        onTranscript: @escaping @Sendable (String, String, Bool) -> Void,
        onSilence: @escaping @Sendable () -> Void
    ) {
        stopOnQueue()
        
        // 1. 筛选支持 on-device 识别的 recognizer
        let recognizers = languageIDs.compactMap { id -> (String, SFSpeechRecognizer)? in
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)),
                  recognizer.supportsOnDeviceRecognition,
                  recognizer.isAvailable else { return nil }
            return (id, recognizer)
        }
        guard recognizers.isEmpty == false else {
            onTranscript("", "", true)  // 触发降级到远程 ASR
            return
        }
        
        // 2. 为每种语言创建独立的 recognition request（多语言并行）
        for (languageID, recognizer) in recognizers {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if #available(macOS 13.0, *) {
                request.requiresOnDeviceRecognition = true  // 强制本地，不上传云端
            }
            if #available(macOS 14.0, *) {
                request.addsPunctuation = true  // 自动加标点
            }
            
            let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let result {
                    let transcript = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if transcript.isEmpty == false {
                        onTranscript(transcript, languageID, result.isFinal)
                    }
                }
                if let error, self?.isStoppingIntentionally != true {
                    // 非主动停止时的错误，静默处理（由其他语言 recognizer 兜底）
                }
            }
            recognitionRequests.append(request)
            recognitionTasks.append(task)
        }
        
        // 3. 静音检测（参照 PowerMeetings）：1.5s 无语音自动触发 onSilence
        // 实际由 AudioRecorder 的 onLevel 回调驱动，这里只注册回调
        isStoppingIntentionally = false
    }
    
    private func stopOnQueue() {
        isStoppingIntentionally = true
        recognitionRequests.forEach { $0.endAudio() }
        recognitionRequests = []
        recognitionTasks.forEach { $0.cancel() }
        recognitionTasks = []
    }
}
```

**PowerMeetings 的关键经验**：
- **多语言并行**：同时启动 `zh-CN` 和 `en-US` 的 recognizer，哪个先出结果用哪个。解决"用户说中英文混合"的识别问题。
- **`requiresOnDeviceRecognition = true`**：强制本地识别，不上传 Apple 云端。保护隐私 + 避免网络延迟。
- **`addsPunctuation = true`**（macOS 14+）：自动加标点，中文识别质量大幅提升。
- **静音检测**：音频电平 < 0.075 持续 1.5s 视为静音，可用于自动断句或提示用户"已停止说话"。
- **非主动停止的错误静默处理**：`isStoppingIntentionally` 标志区分"用户主动停止"和"recognizer 异常退出"，后者不弹错误，由其他并行 recognizer 或降级路径兜底。

#### 4.4.2 大模型 ASR（`RemoteASR`）— 可选项

参照 PowerMeetings `AliyunParaformerTranscriber` 的 WebSocket 流式架构，通用化为任意支持流式音频上传的 ASR 端点（阿里、火山、OpenAI Whisper 等）。

```swift
/// 大模型实时 ASR（WebSocket 流式）。
/// 参照 PowerMeetings AliyunParaformerTranscriber：音频格式转换 + WebSocket 双工 + 自动降级。
final class RemoteASR: ASREngine {
    private let queue = DispatchQueue(label: "Typeless.RemoteASR")
    private let urlSession = URLSession(configuration: .default)
    private var webSocketTask: URLSessionWebSocketTask?
    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var isTaskStarted = false
    private var pendingAudioChunks: [Data] = []
    private var isStoppingIntentionally = false
    
    /// 配置项：endpoint / apiKey / model / sampleRate / format
    func start(
        configuration: ASRRemoteConfig,
        onTranscript: @escaping @Sendable (String, Bool) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) {
        queue.async { [weak self] in
            self?.startOnQueue(configuration: configuration, onTranscript: onTranscript, onStatus: onStatus)
        }
    }
    
    func feed(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let data = self?.convertToTargetFormat(buffer) else { return }
            if self?.isTaskStarted == true {
                self?.webSocketTask?.send(.data(data)) { _ in }
            } else {
                self?.pendingAudioChunks.append(data)
            }
        }
    }
    
    func stop() -> String? {
        queue.sync { [weak self] in
            self?.stopOnQueue()
        }
        return nil
    }
    
    private func startOnQueue(
        configuration: ASRRemoteConfig,
        onTranscript: @escaping @Sendable (String, Bool) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) {
        stopOnQueue()
        
        guard configuration.apiKey.isEmpty == false else {
            onTranscript("", true)  // 触发降级到系统 STT
            return
        }
        
        // 1. 建立 WebSocket 连接
        var request = URLRequest(url: configuration.webSocketURL)
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        let socket = urlSession.webSocketTask(with: request)
        webSocketTask = socket
        socket.resume()
        
        // 2. 接收循环
        receiveLoop(onTranscript: onTranscript, onStatus: onStatus)
        
        // 3. 发送 run-task 指令（协议因厂商而异，这里以阿里为例）
        sendRunTask(configuration: configuration)
        
        // 4. 启动音频引擎，采集 + 格式转换
        startAudioEngine(sampleRate: configuration.sampleRate, onStatus: onStatus)
    }
    
    private func convertToTargetFormat(_ buffer: AVAudioPCMBuffer) -> Data? {
        // 参照 PowerMeetings：AVAudioConverter 将浮点 PCM 转为 Int16 PCM
        guard let converter, let outputFormat else { return nil }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else { return nil }
        
        var error: NSError?
        var didProvideInput = false
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
    
    private func stopOnQueue() {
        isStoppingIntentionally = true
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        audioEngine = nil
        converter = nil
        outputFormat = nil
        pendingAudioChunks = []
        isTaskStarted = false
    }
}
```

**PowerMeetings 的关键经验**：
- **音频格式转换**：麦克风采集是浮点 PCM（`AVAudioFormat` 默认），大模型 ASR 通常要 Int16 PCM。用 `AVAudioConverter` 实时转换，避免先写文件再读取。
- **WebSocket 双工**：先发送 `run-task` 指令，等服务器回 `task-started` 后再开始发音频数据。`pendingAudioChunks` 缓冲早期音频，确保不丢开头。
- **自动降级**：远程 ASR 连接失败 / 未配置 API key → 自动 fallback 到系统 STT。PowerMeetings 的做法是 `onUnavailable` 回调里启动 `LiveSpeechTranscriber`。
- **厂商协议差异**：阿里 Paraformer 用 `wss://dashscope.aliyuncs.com/api-ws/v1/inference`，火山/Whisper 各自不同。配置项里存 `webSocketURL` + `runTaskMessage` 模板，通用化。

#### 4.4.3 ASR 配置与选择策略

```swift
enum ASREngineType: String, Codable, CaseIterable {
    case systemSpeech = "system"      // 默认：SFSpeechRecognizer，本地、免费
    case remote = "remote"            // 可选项：阿里/火山/Whisper 等 WebSocket 流式
}

struct ASRConfig: Codable, Equatable {
    var engine: ASREngineType = .systemSpeech
    var languageIDs: [String] = ["zh-CN", "en-US"]  // 系统 STT 多语言并行
    
    // 远程 ASR 配置（仅 engine == .remote 时有效）
    var remoteProvider: String = "aliyun"  // aliyun | volcengine | whisper
    var remoteEndpoint: String = ""
    var remoteApiKey: String = ""
    var remoteModel: String = "fun-asr-realtime"
    var remoteSampleRate: Int = 16_000
}
```

| 方案 | 优点 | 缺点 | 建议默认 |
|---|---|---|---|
| 系统 Speech | 免费、本地(on-device)、低延迟(~200ms)、隐私安全 | 中文准确率随系统版本；每设备有日配额；语言覆盖有限 | ✅ **默认** |
| 远程 ASR | 准确率高、多语言强、标点好、支持方言 | 联网+付费+1~3s延迟、需配置API key | 可选项 |

**选择策略**：
1. 默认用系统 Speech，开箱即用。
2. 用户可在设置里切换远程 ASR，配置 endpoint + apiKey + model。
3. 远程 ASR 连接失败 / 未配置 → **自动降级到系统 Speech**（PowerMeetings 模式）。
4. 系统 Speech 未授权 / 不可用 → 提示用户去设置里授权或切换远程 ASR。

### 4.5 TextInjector（注入降级链）⚠️ 核心难点

完全照搬 Typeless InputHelper 的两条路径，Swift 原生实现。**这是兼容"任意应用文本框"的关键**。

```
路径 A（优先）：AX API 直写
  取前台 App 焦点 AXUIElement → 设 kAXValueAttribute → 成功=结束
  失败（非文本框/无权限）→ 降级路径 B

路径 B（兜底）：剪贴板 + 模拟 ⌘V（兼容任何接收粘贴的应用）
  1. savePasteboard()     // 备份当前剪贴板全部内容
  2. 写入目标文字到 NSPasteboard.general
  3. simulatePasteCommand()  // CGEvent post ⌘V
  4. 等 PasteDone + setTimeout(100ms) 双保险
  5. restorePasteboard()  // 还原（必须粘贴完成后再还原！）
```

```swift
import ApplicationServices

final class TextInjector {
    /// 高层入口：自动选路径 A，失败降级 B。
    func insert(_ text: String) async {
        if axInsert(text) { return }          // 路径 A
        await pasteInsert(text)                // 路径 B
    }

    // 路径 A：AX API 直写（对原生 App / Electron 友好）
    private func axInsert(_ text: String) -> Bool {
        let focused = AXUIElement.systemFocusedElement ?? return false
        // 设值；某些控件需要 AXTextField 子角色
        let err = AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, text as CFTypeRef)
        return err == .success
    }

    // 路径 B：剪贴板 + 模拟粘贴（兼容任意支持 ⌘V 的应用）
    private func pasteInsert(_ text: String) async {
        let snapshot = savePasteboard()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        simulateCmdV()
        try? await Task.sleep(for: .milliseconds(150))   // 等粘贴完成
        restorePasteboard(snapshot)
    }

    private func simulateCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x36 /*cmd*/, keyDown: true)!
        let vDown   = CGEvent(keyboardEventSource: source, virtualKey: 0x09 /*v*/,   keyDown: true)!
        vDown.flags = .maskCommand
        let vUp     = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)!
        vUp.flags   = .maskCommand
        let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x36, keyDown: false)!
        cmdDown.post(tap: .cgi); vDown.post(tap: .cgi); vUp.post(tap: .cgi); cmdUp.post(tap: .cgi)
    }
}
```

**关键时序坑（Typeless 文档强调）**：`restorePasteboard` 必须在 `simulatePasteCommand` **完成之后**，否则粘贴读到的是还原后的旧内容。用 `Task.sleep(150ms)` 双保险。

**权限**：路径 A 和路径 B 都需要 **Accessibility** 权限。AX API 无权限时 `AXIsProcessTrusted()` 为 false。

### 4.6 ContextCollector（C 流程的上下文采集）

C 流程要把"选中文本 / 剪贴板图片 / 剪贴板文字"作为上下文喂给多模态 LLM。

```swift
struct CollectedContext {
    var selectedText: String?      // 优先 AX 读，失败模拟 ⌘C
    var clipboardText: String?     // NSPasteboard .string
    var clipboardImage: Data?      // NSPasteboard .tiff/.png
}

final class ContextCollector {
    /// 读选中文本：优先 AX API（无副作用），失败降级模拟 ⌘C（有副作用，会污染剪贴板，需 save/restore）。
    func collect() async -> CollectedContext {
        var ctx = CollectedContext()
        if let ax = axSelectedText() { ctx.selectedText = ax }
        else { ctx.selectedText = await selectedTextBySimulateCopy() }
        ctx.clipboardText = NSPasteboard.general.string(forType: .string)
        ctx.clipboardImage = NSPasteboard.general.data(forType: .tiff) ?? NSPasteboard.general.data(forType: .png)
        return ctx
    }
}
```

> 与 Typeless 一致：`getSelectedText`（AX）优先，失败用 `getSelectedTextBySimulateCopyAsync`（模拟 ⌘C 读剪贴板）。后者有副作用，必须包在 save/restore 里。

### 4.7 Pipeline 编排（把上面串起来）

```swift
@MainActor
extension Pipeline {
    private func startRecording() async {
        do {
            try recorder.start(inputDevice: settings.audioInputDevice) { [weak asr] buf in
                asr?.feed(buf)   // 系统STT流式喂 buffer
            }
            phase = .recording
        } catch { lastError = error.localizedDescription; phase = .idle }
    }

    private func stopAndProcess(action: Action) async {
        phase = .processing(action: action)
        recorder.stop()
        do {
            let text = try await asr.finalize()      // 拿转写结果
            switch action {
            case .dictate:
                await injector.insert(text)
            case .translate:
                let translated = try await llm.translate(text, to: settings.targetLanguage)
                await injector.insert(translated)
            case .assist:
                let ctx = await context.collect()
                let answer = try await llm.assist(transcription: text, context: ctx)
                await injector.insert(answer)
            }
        } catch { lastError = error.localizedDescription }
        phase = .idle
    }
}
```

### 4.8 LLMClient（移植 PTerminal 的双协议抽象）

直接对照 PTerminal `src-tauri/src/ai/mod.rs` 的 `Provider` 枚举和 `ai/client.rs` 的 `test_connection`，用 Swift 重写。**不需要 reqwest，用 URLSession**。

```swift
enum Provider: String, Codable { case openai, anthropic }

struct LLMConfig: Codable {
    var textProvider: Provider = .openai
    var textApiKey: String = ""
    var textModel: String = "gpt-4o-mini"
    var textBaseUrl: String = "https://api.openai.com"

    var visionProvider: Provider = .openai       // 多模态
    var visionApiKey: String = ""
    var visionModel: String = "gpt-4o"
    var visionBaseUrl: String = "https://api.openai.com"
}

final class LLMClient {
    /// 文字：翻译。
    func translate(_ text: String, to lang: String) async throws -> String { ... }
    /// 多模态：转写文字 + 上下文（含图片）。
    func assist(transcription: String, context: CollectedContext) async throws -> String { ... }
}
```

参照 PTerminal 的 `joinApiUrl`（容忍 base 含 `/v1`）和两种协议的请求体差异（OpenAI 用 `/chat/completions` + `messages`；Anthropic 用 `/v1/messages` + `x-api-key` 头）。

---

## 5. 权限清单 ⚠️ 最易踩坑

| 权限 | 用途 | 配置位置 | 引导方式 |
|---|---|---|---|
| **Input Monitoring** | CGEventTap 监听全局键（需求 3） | 系统设置 → 隐私 → 输入监控 | `CGEvent.tapCreate` 返回 nil → 打开对应面板 |
| **Accessibility** | AX API 注入文字 + 模拟 ⌘V + 读选中文本（需求 3 注入） | 系统设置 → 隐私 → 辅助功能 | `AXIsProcessTrusted()` 为 false → 弹引导 |
| **Microphone** | 录音（需求 2） | Info.plist `NSMicrophoneUsageDescription` + 运行时授权 | `AVAudioApplication.requestRecordPermission` |
| **Speech Recognition** | 系统 STT（需求 2） | Info.plist `NSSpeechRecognitionUsageDescription` + `SFSpeechRecognizer.requestAuthorization` | 运行时弹窗 |

**关键认知**：
- Input Monitoring 和 Accessibility **不在 plist 里**，是运行时由用户在系统设置勾选。App 首次启动必须检测并引导（开 `Preferences → Privacy & Security` 的对应深链）。
- 沙盒 App 默认拿不到全局事件。**建议不沙盒化**（entitlements 里不勾 App Sandbox），或仔细配置临时例外。CD-Switch 就是非沙盒的 accessory App。

```swift
// Permissions.swift
func ensureAccessibility() -> Bool {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(opts)   // 同时弹系统提示
}
```

---

## 6. 数据模型与持久化

参照 CD-Switch `AppState` 的做法：`@Published` + `UserDefaults` + `Codable`，`didSet` 自动存盘。

```swift
@MainActor
final class AppSettings: ObservableObject {
    @Published var llm: LLMConfig { didSet { save() } }
    @Published var asr: ASRConfig { didSet { save() } }
    @Published var shortcuts: ShortcutsConfig { didSet { save(); monitor.update(shortcuts) } }
    @Published var targetLanguage: String { didSet { save() } }   // B 翻译目标
    @Published var audioInputDevice: AudioDeviceID? { didSet { save() } }

    private let defaults = UserDefaults.standard

    init() {
        self.llm = load(.llm) ?? .init()
        self.asr = load(.asr) ?? .init()
        // ...
    }
    private func save() { /* JSONEncoder → defaults.set */ }
}
```

配置项分组：

| 配置 | 字段 |
|---|---|
| 文字模型 | provider / apiKey / model / baseUrl |
| 多模态模型 | provider / apiKey / model / baseUrl |
| ASR | engine(`system`/`remote`) / remote endpoint / api key |
| 快捷键 | A/B/C 各自的 keyCode + modifier mask（点设置里"录制快捷键"捕获） |
| 翻译目标语言 | 如 "English" / "中文" |
| 音频输入设备 | AudioDeviceID（菜单栏直接选） |

---

## 7. 菜单栏（直接参照 CD-Switch）

CD-Switch 的 `ClaudeSwitchApp.swift` + `MenuBarMenu.swift` 几乎可以照搬，只换菜单项：

```swift
@main
struct TypelessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var pipeline = Pipeline()

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu().environmentObject(pipeline)
        } label: {
            // 录音中/处理中/空闲 三态图标
            Image(systemName: pipeline.phase.iconName)
        }
        Window("Typeless 设置", id: "settings") {
            SettingsWindow().environmentObject(pipeline)
        }
    }
}
// AppDelegate.applicationDidFinishLaunching:
NSApp.setActivationPolicy(.accessory)   // 不进 Dock
```

菜单项（需求 4）：
```
─────────────
录音状态: 空闲 / 录音中 (●) / 处理中 (⚙)
─────────────
设置…              → openWindow("settings")
─────────────
音频输入源 ▶       → 子菜单列设备（菜单栏直接选，✓ 当前）
─────────────
退出 Typeless      ⌘Q
```

`AppDelegate.applicationShouldTerminateAfterLastWindowClosed` 返回 `false`（关设置窗口不退出 App），与 CD-Switch 一致。

---

## 8. 分阶段实施路线图

参照 Typeless 文档 §6"最小清单"的思路：每个阶段都有可演示产物，不要一次性写完所有模块。

| 阶段 | 产出 | 可演示 |
|---|---|---|
| **1. 骨架** | fork CD-Switch 结构 → `MenuBarExtra` + 设置空窗口 + 退出。`LSUIElement=true` | 菜单栏图标点击出菜单 |
| **2. 权限** | `Permissions.swift`：检测 + 引导 Accessibility/Input Monitoring/Mic/Speech | 首次启动引导授权 |
| **3. 快捷键监听** | `KeyboardMonitor`(CGEventTap) + `ShortcutDetector` + 设置里录制快捷键 | 按键时日志/菜单显示命中 |
| **4. 注入** | `TextInjector` 路径 A+B；在备忘录里验证 | 按快捷键插入固定测试文本 |
| **5. 录音+系统 STT** | `AudioRecorder` + `SystemSpeechASR`；A 键跑通 | 按 A 说话 → 再按 A → 文字进文本框 |
| **6. LLM + 翻译** | `LLMClient`（移植 PTerminal）；B 键跑通 | 按 B 说中文 → 再按 B → 英文进文本框 |
| **7. 多模态+上下文** | `ContextCollector`；C 键跑通 | 选中文字+剪贴板图片 → 按 C → 处理结果 |
| **8. 打磨** | 音频源选择菜单、错误提示、开机启动、图标三态、大模型 ASR 选项 | 可日常使用 |

---

## 9. 已知坑（来自 Typeless 文档 §4 + Swift 实践）

| 现象 | 原因 | 处理 |
|---|---|---|
| CGEventTap 不触发 | 未授权 Input Monitoring | `tapCreate` 返回 nil 检测 + 打开系统设置深链 |
| AX 注入对某些 App 失败 | 焦点元素不响应 `kAXValueAttribute` | 降级路径 B（剪贴板+⌘V） |
| 路径 B 剪贴板被污染 | restore 早于 paste 完成 | `Task.sleep(150ms)` 双保险 |
| 系统 STT 偶发无结果 | 每设备每日有配额；locale 不支持 | fallback 提示切大模型 ASR |
| 模拟 ⌘V 触发 App 自身快捷键 | 注入目标 App 把 ⌘V 绑了别的 | 不可完全避免，路径 A 优先可规避 |
| CGEvent 回调 crash | 跨线程访问 UI | 回调里只取数据，`DispatchQueue.main.async` 回主线程改 UI |
| 麦克风授权后仍录不到 | AVAudioEngine input tap 时机错 | 先 `requestRecordPermission` 再 `installTap` |
| `setActivationPolicy(.accessory)` 后设置窗口不聚焦 | accessory 模式窗口需手动 activate | `NSApp.activate(ignoringOtherApps: true)`（CD-Switch 已验证） |

---

## 10. 与四个参考的对应关系（速查）

| 本方案模块 | 参考来源 | 取什么 |
|---|---|---|
| `TypelessApp` / `MenuBarMenu` | CD-Switch `ClaudeSwitchApp.swift` / `MenuBarMenu.swift` | 菜单栏 App 骨架、accessory 模式、窗口管理 |
| `AppSettings` | CD-Switch `AppState.swift` | UserDefaults + @Published + didSet 自动存盘 |
| `Info.plist` `LSUIElement` | CD-Switch `Info.plist` | 菜单栏 App 标识 |
| `KeyboardMonitor` / `ShortcutDetector` | Typeless `KeyboardHelper`（§1） | 领域逻辑（CGEventTap、按键匹配、keyCode 映射） |
| `TextInjector` | Typeless `InputHelper`（§2） | 路径 A/B 降级链、save/restore 时序 |
| `ContextCollector` | Typeless `ContextHelper` + `InputHelper.getSelectedText` | 选中文本/剪贴板采集 |
| `AudioRecorder` | PowerMeetings `NoiseSuppressingMicrophoneRecorder` | 高通滤波 + 软噪声门 + 音频电平检测 |
| `SystemSpeechASR` | PowerMeetings `LiveSpeechTranscriber` | 多语言并行、on-device、静音检测、自动标点 |
| `RemoteASR` | PowerMeetings `AliyunParaformerTranscriber` | WebSocket 流式、音频格式转换、pending 缓冲、自动降级 |
| `LLMClient` | PTerminal `ai/mod.rs` + `ai/client.rs` | Provider 双协议抽象、`joinApiUrl`、test_connection |
| 设置 UI | PTerminal `SettingsPage.tsx` | provider/apiKey/model/baseUrl 表单 + 测试连接按钮 |

> 四份参考里，**Typeless 文档给的是"做什么/为什么"（领域逻辑），CD-Switch 给的是"Swift 怎么搭壳"，PTerminal 给的是"AI 怎么配"，PowerMeetings 给的是"ASR 怎么做得可靠"**。四者合一就是本方案。
