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
            if let statusImage = NSImage(named: "StatusIcon") {
                Image(nsImage: statusImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: pipeline.phase.iconName)
                    .renderingMode(.template)
            }
        }
        .menuBarExtraStyle(.menu)

        Window("Typeless Settings", id: "settings") {
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
        case .idle:       return "mic.fill"
        case .recording:  return "mic.circle.fill"
        case .processing: return "gearshape.fill"
        }
    }
}
