import SwiftUI

struct MenuBarMenu: View {
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var permissions: Permissions
    @EnvironmentObject private var pipeline: Pipeline
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Audio input submenu
        audioInputSection

        Divider()

        // Actions
        Button("Settings...") { showSettingsWindow() }
            .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit OpenTypeless") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var audioInputSection: some View {
        Menu("Audio Input Device") {
            let isSystemDefaultSelected = appSettings.audioInputDeviceID.isEmpty
            Button(isSystemDefaultSelected ? "✓ System Default" : "System Default") {
                appSettings.audioInputDeviceID = ""
            }

            if permissions.audioDevices.isEmpty {
                Text("No audio devices found")
                    .foregroundColor(.secondary)
            } else {
                Divider()
                ForEach(permissions.audioDevices, id: \.id) { device in
                    let isSelected = device.id == appSettings.audioInputDeviceID
                    Button(isSelected ? "✓ \(device.name)" : device.name) {
                        appSettings.audioInputDeviceID = device.id
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func showSettingsWindow() {
        let existing = NSApp.windows.first {
            $0.isVisible && !($0 is NSPanel) &&
            ($0.identifier?.rawValue == "settings")
        }
        if let window = existing {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openWindow(id: "settings")
            // 新窗口也要激活 App，否则菜单栏 App 打开的窗口不获焦点
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}
