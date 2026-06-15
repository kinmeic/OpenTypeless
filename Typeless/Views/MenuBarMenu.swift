import SwiftUI

struct MenuBarMenu: View {
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var permissions: Permissions
    @EnvironmentObject private var pipeline: Pipeline
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Recording status
        statusSection

        Divider()

        // Audio input submenu
        audioInputSection

        Divider()

        // Actions
        Button("Settings...") { showSettingsWindow() }
            .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Typeless") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var statusSection: some View {
        let (statusText, icon, color) = statusInfo
        Label(statusText, systemImage: icon)
            .foregroundColor(color)

        if let error = pipeline.lastError {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(error)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundColor(.red)
                Spacer()
                Button("Dismiss") {
                    pipeline.clearError()
                    NotificationManager.shared.clearError()
                }
                .buttonStyle(.plain)
                .font(.caption)
            }
            .padding(.vertical, 2)
        }
    }

    private var statusInfo: (String, String, Color) {
        switch pipeline.phase {
        case .idle:
            return ("Ready to record", "mic.fill", .secondary)
        case .recording:
            return ("Recording... (press shortcut to stop)", "mic.circle.fill", .red)
        case .processing(let action):
            let actionName: String
            switch action {
            case .dictate: actionName = "Dictating"
            case .translate: actionName = "Translating"
            case .assist: actionName = "Assisting"
            }
            return ("\(actionName)...", "gearshape.fill", .orange)
        }
    }

    @ViewBuilder
    private var audioInputSection: some View {
        Menu("Audio Input Source") {
            if permissions.audioDevices.isEmpty {
                Text("No audio devices found")
                    .foregroundColor(.secondary)
            } else {
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
        }
    }
}
