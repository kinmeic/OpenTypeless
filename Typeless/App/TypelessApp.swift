import SwiftUI
import Cocoa

@main
struct TypelessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appSettings = AppSettings.shared
    @StateObject private var permissions = Permissions.shared
    @StateObject private var pipeline = Pipeline()

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(appSettings)
                .environmentObject(permissions)
                .environmentObject(pipeline)
        } label: {
            Image(systemName: pipeline.phase.iconName)
                .renderingMode(.template)
                .imageScale(.medium)
                .foregroundColor(pipeline.phase.iconColor)
        }
        .menuBarExtraStyle(.menu)

        Window("OpenTypeless Settings", id: "settings") {
            SettingsWindow()
                .environmentObject(appSettings)
                .environmentObject(permissions)
                .environmentObject(pipeline)
                .frame(minWidth: 600, minHeight: 450)
        }
        .defaultSize(width: 700, height: 500)
    }
}

extension Pipeline.Phase {
    var iconName: String {
        switch self {
        case .idle:       return "waveform"          // 静态波形：待命
        case .recording:  return "waveform"          // 红色波形：录音中
        case .processing: return "waveform.circle"   // 圆框波形：处理中
        }
    }

    var iconColor: Color {
        switch self {
        case .idle:       return .secondary      // 灰：待命
        case .recording:  return .red            // 红：录音中
        case .processing: return .blue           // 蓝：处理中
        }
    }
}
