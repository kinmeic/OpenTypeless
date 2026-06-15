import SwiftUI

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
        }
        .padding()
        .frame(minWidth: 600, minHeight: 450)
    }
}

// MARK: - General Tab

struct SettingsGeneralTab: View {
    @EnvironmentObject private var permissions: Permissions

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionRow(
                    label: "Accessibility",
                    granted: permissions.accessibilityGranted,
                    action: permissions.openAccessibilitySettings
                )
                PermissionRow(
                    label: "Input Monitoring",
                    granted: permissions.inputMonitoringGranted,
                    action: permissions.openInputMonitoringSettings
                )
                PermissionRow(
                    label: "Microphone",
                    granted: permissions.microphoneGranted,
                    action: permissions.requestMicrophone
                )
                PermissionRow(
                    label: "Speech Recognition",
                    granted: permissions.speechRecognitionGranted,
                    action: permissions.requestSpeechRecognition
                )
            }

            Section("Audio") {
                // Audio device picker will go here
                Text("Audio input device selection coming soon")
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
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
    @State private var textTestResult: String?
    @State private var visionTestResult: String?

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
                    Text("OpenAI").tag("openai")
                    Text("Anthropic").tag("anthropic")
                }
                SecureField("API Key", text: $appSettings.llm.visionApiKey)
                TextField("Model", text: $appSettings.llm.visionModel)
                TextField("Base URL", text: $appSettings.llm.visionBaseUrl)

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
}

// MARK: - ASR Tab

struct SettingsASRTab: View {
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        Form {
            Section("Speech-to-Text Engine") {
                Picker("Engine", selection: $appSettings.asr.engine) {
                    ForEach(ASREngineType.allCases, id: \.self) { engine in
                        Text(engine.rawValue.capitalized).tag(engine)
                    }
                }

                if appSettings.asr.engine == .remote {
                    TextField("Provider", text: $appSettings.asr.remoteProvider)
                    TextField("Endpoint", text: $appSettings.asr.remoteEndpoint)
                    TextField("API Key", text: $appSettings.asr.remoteApiKey)
                    TextField("Model", text: $appSettings.asr.remoteModel)
                    HStack {
                        Text("Sample Rate:")
                        Spacer()
                        TextField("", value: $appSettings.asr.remoteSampleRate, format: .number.grouping(.never))
                            .frame(width: 100)
                    }
                } else {
                    // 系统 STT 多语言配置
                    Text("Languages: \(appSettings.asr.languageIDs.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("On-device recognition enabled. Auto-punctuation on (macOS 14+).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Translation") {
                TextField("Target Language (for B key)", text: $appSettings.targetLanguage)
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
