# OpenTypeless

**Speak. Type. Anywhere.** A macOS menu-bar utility that turns your voice into
typed text in any app — transcribe, refine, translate, or ask an LLM, all from
global keyboard shortcuts.

OpenTypeless listens for three configurable global shortcuts and handles the
audio capture → speech recognition → LLM post-processing → text injection
pipeline for you, inserting the result right where your cursor is.

## ✨ Features

- **A · Dictate** — Speech-to-text. Transcribes your voice, cleans up filler
  words, and formats it with conservative line breaks (greetings, sign-offs,
  lists) before typing it at the cursor.
- **B · Translate** — Dictate + translate into your target language, preserving
  the same clean formatting.
- **C · Assist** — Capture speech *plus* the currently selected text as context,
  then let an LLM answer and show the result in a popup.
- **Dual ASR engines**
  - *System*: on-device macOS speech recognition (macOS 14+), no network needed.
  - *LLM Model*: any OpenAI-compatible transcription API or Aliyun Qwen-ASR.
- **Bring-your-own LLM** — works with any OpenAI-compatible or Anthropic-compatible
  endpoint (GLM, DeepSeek, Qwen, MiniMax, Ollama, LM Studio, …). Dedicated ASR
  and text providers can be configured independently.
- **Menu-bar resident** — lives in your status bar, no Dock icon, ready to record.
- **Private by design** — your API key and settings stay in your local
  UserDefaults; nothing is sent anywhere except the provider you configure.

## 🚀 Getting Started

1. Build with Xcode 15+ (macOS 14 Sonoma or later). If you modify the project
   layout, run `xcodegen generate` first, then build the `OpenTypeless` scheme.
2. Launch and grant **Accessibility**, **Input Monitoring**, **Microphone**, and
   **Speech Recognition** permissions.
3. Set your shortcuts and provider in **Settings**.
4. Hold a shortcut, speak, release — done.

## ⌨️ Default Shortcuts

| Action | Default | What it does |
|--------|---------|--------------|
| Dictate | ⌥1 | Transcribe + format → type at cursor |
| Translate | ⌥2 | Transcribe + translate → type at cursor |
| Assist | ⌥3 | Speech + selected text → LLM answer popup |

All shortcuts are fully configurable in **Settings → Shortcuts**.

## 🛠 Tech

- Swift / SwiftUI, menu-bar (`LSUIElement`) app
- Combine + `@MainActor` pipeline, `AVAudioEngine` capture
- xcodegen-managed project, XCTest test suite

## 📄 License

Released under the [BSD 3-Clause License](./LICENSE).
