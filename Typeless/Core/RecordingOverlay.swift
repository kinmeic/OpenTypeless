import Foundation
import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.typeless.app", category: "overlay")

/// 录音浮层管理：用一个 NSPanel（floating、non-activating）在屏幕底部居中显示录音状态。
///
/// Panel 不抢焦点（non-activating），可跨 Space 显示（canJoinAllSpaces），
/// 进入/退出 recording 状态时显示/隐藏。
@MainActor
final class RecordingOverlay {
    static let shared = RecordingOverlay()

    private var panel: NSPanel?

    /// 显示浮层。
    func show(pipeline: Pipeline) {
        if panel == nil {
            createPanel(pipeline: pipeline)
        }
        guard let panel else { return }

        // 重新定位到屏幕底部居中
        positionAtBottomCenter(panel)

        if !panel.isVisible {
            panel.orderFrontRegardless()
            logger.info("Recording overlay shown")
        }
    }

    /// 隐藏浮层。
    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        logger.info("Recording overlay hidden")
    }

    // MARK: - Panel Creation

    private func createPanel(pipeline: Pipeline) {
        let size = NSSize(width: 340, height: 70)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false

        // SwiftUI 内容
        let hosting = NSHostingView(rootView: RecordingOverlayView().environmentObject(pipeline))
        panel.contentView = hosting

        self.panel = panel
    }

    private func positionAtBottomCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let size = panel.frame.size
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.minY + 60  // 距底部 60pt
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
