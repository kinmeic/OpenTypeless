import SwiftUI
import CoreAudio

struct SettingsWindow: View {
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var permissions: Permissions

    var body: some View {
        TabView {
            SettingsGeneralTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            SettingsLLMTab()
                .tabItem {
                    Label("LLM", systemImage: "cpu")
                }
            SettingsASRTab()
                .tabItem {
                    Label("ASR", systemImage: "waveform")
                }
            SettingsShortcutsTab()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
            SettingsTestTab()
                .tabItem {
                    Label("Test", systemImage: "play.circle")
                }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 450)
    }
}

// MARK: - General Tab

struct SettingsGeneralTab: View {
    @EnvironmentObject private var permissions: Permissions
    @EnvironmentObject private var appSettings: AppSettings

    @State private var inputDevices: [AudioDeviceManager.Device] = []
    @StateObject private var levelMonitor = AudioLevelMonitor()

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionRow(
                    label: "Accessibility",
                    granted: permissions.accessibilityGranted,
                    action: permissions.requestAccessibility
                )
                PermissionRow(
                    label: "Input Monitoring",
                    granted: permissions.inputMonitoringGranted,
                    action: permissions.requestInputMonitoring
                )
                PermissionRow(
                    label: "Microphone",
                    granted: permissions.microphoneGranted,
                    action: { permissions.requestMicrophone() }
                )
                PermissionRow(
                    label: "Speech Recognition",
                    granted: permissions.speechRecognitionGranted,
                    action: permissions.requestSpeechRecognition
                )
            }

            Section("Audio") {
                Picker("Input Device", selection: $appSettings.audioInputDeviceID) {
                    Text("System Default").tag("")
                    ForEach(inputDevices) { device in
                        Text(device.name).tag("\(device.id)")
                    }
                }
                .onChange(of: appSettings.audioInputDeviceID) { _ in
                    // 设备切换时若正在监测，重启监测器以应用新设备
                    if levelMonitor.isRunning {
                        let id = AudioDeviceID(appSettings.audioInputDeviceID) ?? 0
                        levelMonitor.start(deviceID: id)  // start 内部会先 stop 再重启
                    }
                }

                // 实时电平条
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundColor(.secondary)
                    ProgressView(value: levelMonitor.level)
                        .progressViewStyle(.linear)
                        .tint(levelMonitor.level > 0.08 ? .green : .secondary)
                    Text(String(format: "%3.0f%%", levelMonitor.level * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                // Test Input 和 Refresh Devices 同行
                HStack {
                    Button(levelMonitor.isRunning ? "Stop Test" : "Test Input") {
                        if levelMonitor.isRunning {
                            levelMonitor.stop()
                        } else {
                            startInputTest()
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("Refresh Devices") {
                        inputDevices = AudioDeviceManager.inputDevices()
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
            }

            Section("Recording") {
                Toggle("Mute system output while recording", isOn: $appSettings.muteSystemAudioDuringRecording)
                Toggle("Play interaction sound", isOn: $appSettings.playInteractionSound)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            inputDevices = AudioDeviceManager.inputDevices()
        }
        .onDisappear {
            // 离开设置页时停止监测，释放麦克风
            if levelMonitor.isRunning {
                levelMonitor.stop()
            }
        }
    }

    private func startInputTest() {
        if permissions.microphoneGranted {
            startLevelMonitor()
        } else {
            permissions.requestMicrophone { granted in
                guard granted else { return }
                startLevelMonitor()
            }
        }
    }

    private func startLevelMonitor() {
        let id = AudioDeviceID(appSettings.audioInputDeviceID) ?? 0
        levelMonitor.start(deviceID: id)
        permissions.refreshAll()
    }
}

struct PermissionRow: View {
    let label: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(granted ? .green : .red)
            Button("Grant") { action() }
                .disabled(granted)
        }
    }
}

// MARK: - LLM Tab

struct SettingsLLMTab: View {
    @EnvironmentObject private var appSettings: AppSettings

    @State private var testingText = false
    @State private var testingVision = false
    @State private var testingASR = false
    @State private var textTestResult: String?
    @State private var visionTestResult: String?
    @State private var asrTestResult: String?

    var body: some View {
        Form {
            Section("Text Model") {
                Picker("Provider", selection: $appSettings.llm.textProvider) {
                    Text("OpenAI").tag("openai")
                    Text("Anthropic").tag("anthropic")
                }
                SecureField("API Key", text: $appSettings.llm.textApiKey)
                TextField("Model", text: $appSettings.llm.textModel)
                TextField("Base URL", text: $appSettings.llm.textBaseUrl)

                Button("Test Connection") {
                    testTextConnection()
                }
                .disabled(testingText)
                .buttonStyle(.bordered)

                if let result = textTestResult {
                    Text(result)
                        .font(.caption)
                        .foregroundColor(result.hasPrefix("✓") ? .green : .red)
                }
            }

            Section("Vision Model") {
                Picker("Provider", selection: $appSettings.llm.visionProvider) {
                    Text("Same as Text Model").tag("same")
                    Text("OpenAI").tag("openai")
                    Text("Anthropic").tag("anthropic")
                }
                .onChange(of: appSettings.llm.visionProvider) { newValue in
                    appSettings.llm.visionProviderSameAsText = (newValue == "same")
                }

                if appSettings.llm.visionProvider != "same" {
                    SecureField("API Key", text: $appSettings.llm.visionApiKey)
                    TextField("Base URL", text: $appSettings.llm.visionBaseUrl)
                }

                TextField("Model", text: $appSettings.llm.visionModel)

                Button("Test Connection") {
                    testVisionConnection()
                }
                .disabled(testingVision)
                .buttonStyle(.bordered)

                if let result = visionTestResult {
                    Text(result)
                        .font(.caption)
                        .foregroundColor(result.hasPrefix("✓") ? .green : .red)
                }
            }

            Section("ASR Model") {
                Picker("Provider", selection: $appSettings.llm.asrProvider) {
                    Text("Same as Text Model").tag("same")
                    Text("OpenAI").tag("openai")
                    Text("Anthropic").tag("anthropic")
                }
                .onChange(of: appSettings.llm.asrProvider) { newValue in
                    appSettings.llm.asrProviderSameAsText = (newValue == "same")
                }

                if appSettings.llm.asrProvider != "same" {
                    SecureField("API Key", text: $appSettings.llm.asrApiKey)
                    TextField("Base URL", text: $appSettings.llm.asrBaseUrl)
                }

                TextField("Model", text: $appSettings.llm.asrModel)

                Button("Test Connection") {
                    testASRConnection()
                }
                .disabled(testingASR)
                .buttonStyle(.bordered)

                if let result = asrTestResult {
                    Text(result)
                        .font(.caption)
                        .foregroundColor(result.hasPrefix("✓") ? .green : .red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func testTextConnection() {
        testingText = true
        textTestResult = nil
        Task {
            let result = await LLMClient().testConnection(config: appSettings.llm, useVisionConfig: false)
            await MainActor.run {
                textTestResult = (result.ok ? "✓ " : "✗ ") + result.message
                testingText = false
            }
        }
    }

    private func testVisionConnection() {
        testingVision = true
        visionTestResult = nil
        Task {
            let result = await LLMClient().testConnection(config: appSettings.llm, useVisionConfig: true)
            await MainActor.run {
                visionTestResult = (result.ok ? "✓ " : "✗ ") + result.message
                testingVision = false
            }
        }
    }

    private func testASRConnection() {
        testingASR = true
        asrTestResult = nil
        Task {
            let result = await LLMClient().testConnection(config: appSettings.llm, useASRConfig: true)
            await MainActor.run {
                asrTestResult = (result.ok ? "✓ " : "✗ ") + result.message
                testingASR = false
            }
        }
    }
}

// MARK: - ASR Tab

struct SettingsASRTab: View {
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        Form {
            Section("Speech-to-Text Engine") {
                Picker("Engine", selection: $appSettings.asr.engine) {
                    Text("System").tag(ASREngineType.systemSpeech)
                    Text("ASR Model").tag(ASREngineType.llm)
                }

                if appSettings.asr.engine == .llm {
                    Text("Uses the ASR Model configured in the LLM tab (e.g. GLM-ASR-2512 via OpenAI-compatible API).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if appSettings.asr.engine == .systemSpeech {
                    Picker("Recognition Language", selection: $appSettings.asr.recognitionLanguageID) {
                        ForEach(ASRConfig.supportedSystemLanguages) { language in
                            Text(language.name).tag(language.id)
                        }
                    }
                    Text("On-device recognition enabled. Auto-punctuation on (macOS 14+).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Translation") {
                Picker("Target Language (for B key)", selection: $appSettings.targetLanguage) {
                    Text("英语").tag("English")
                    Text("中文").tag("Chinese")
                    Text("日语").tag("Japanese")
                    Text("韩语").tag("Korean")
                    Text("法语").tag("French")
                    Text("西班牙语").tag("Spanish")
                    Text("德语").tag("German")
                    Text("意大利语").tag("Italian")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts Tab

struct SettingsShortcutsTab: View {
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        Form {
            Section("A — Dictate (Speech to Text)") {
                ShortcutRecorder(config: $appSettings.shortcuts.a)
            }
            Section("B — Translate (Speech to Text + Translate)") {
                ShortcutRecorder(config: $appSettings.shortcuts.b)
            }
            Section("C — Assist (Speech + Context + LLM)") {
                ShortcutRecorder(config: $appSettings.shortcuts.c)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutRecorder: View {
    @Binding var config: ShortcutConfig
    @State private var isRecording = false
    @State private var localMonitor: Any? = nil

    var body: some View {
        HStack {
            Text(displayString)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 120, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isRecording ? Color.yellow.opacity(0.2) : Color.clear)
                .cornerRadius(6)

            Button(isRecording ? "Recording..." : "Record") {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .yellow : .accentColor)
        }
    }

    private func startRecording() {
        isRecording = true
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 忽略纯修饰键（没有实际字符的按键）
            if event.keyCode == 0x3B || event.keyCode == 0x3A || event.keyCode == 0x37 || event.keyCode == 0x38 {
                return event
            }
            let mods = Int(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
            config.keyCode = Int(event.keyCode)
            config.modifierFlags = mods
            stopRecording()
            return nil // consume the event so it doesn't trigger anything else
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private var displayString: String {
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(config.modifierFlags))
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if let keyName = KeyCodes.name(for: config.keyCode) {
            parts.append(keyName)
        }
        return parts.isEmpty ? "Not set" : parts.joined(separator: "+")
    }
}

// MARK: - Test Tab

/// 测试页：文本输入框（注入目标）+ 4 个按钮，方便不用快捷键也能测试完整流程。
struct SettingsTestTab: View {
    @EnvironmentObject private var pipeline: Pipeline
    @EnvironmentObject private var appSettings: AppSettings

    @State private var text: String = ""
    @FocusState private var textFocused: Bool

    /// 是否处于录音状态（按钮可用性判断）。
    private var isRecording: Bool {
        if case .recording = pipeline.phase { return true }
        return false
    }

    private var isProcessing: Bool {
        if case .processing = pipeline.phase { return true }
        return false
    }

    var body: some View {
        Form {
            Section("Input") {
                TextEditor(text: $text)
                    .frame(minHeight: 120)
                    .focused($textFocused)
                    .font(.body)

                Text("Results are shown here for A/B.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Actions") {
                // 开始/停止录音：idle 时开始，recording 时是无效（停止由下面 3 个按钮触发）
                Button {
                    pipeline.handleShortcut(action: .dictate)
                } label: {
                    Label(isRecording ? "Recording… (use a button below to stop)" : "Start Recording", systemImage: isRecording ? "stop.circle.fill" : "mic.fill")
                }
                .disabled(isProcessing || isRecording)
                .tint(isRecording ? .red : .accentColor)

                // A：语音转文字（停止录音 → 转写 → 注入到文本框）
                Button {
                    pipeline.handleTestAction(action: .dictate) { result in
                        appendResult(result)
                    }
                } label: {
                    Label("A · Speech to Text", systemImage: "text.alignleft")
                }
                .disabled(isProcessing || isRecording == false)
                .tint(.blue)

                // B：翻译（停止录音 → 转写 → 翻译成目标语言 → 注入）
                Button {
                    pipeline.handleTestAction(action: .translate) { result in
                        appendResult(result)
                    }
                } label: {
                    Label("B · Translate (\(appSettings.targetLanguage))", systemImage: "globe")
                }
                .disabled(isProcessing || isRecording == false)
                .tint(.blue)

                // C：随便问（停止录音 → 转写 → 采集上下文 → LLM 处理 → 弹窗显示）
                Button {
                    pipeline.handleShortcut(action: .assist)
                } label: {
                    Label("C · Ask (result in popup)", systemImage: "sparkles")
                }
                .disabled(isProcessing || isRecording == false)
                .tint(.blue)
            }

            if let err = pipeline.lastError {
                Section("Error") {
                    Text(err)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { textFocused = true }
    }

    private func appendResult(_ result: String) {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = trimmed
        } else {
            text += (text.hasSuffix("\n") ? "" : "\n") + trimmed
        }
        textFocused = true
    }
}
