import Foundation
import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.typeless.app", category: "result-overlay")

/// 结果浮层管理：用 NSPanel 显示 LLM（C 键）的答案，居中显示，不抢主焦点但可交互（选择/复制）。
///
/// 与录音浮层不同，这个 panel 需要可交互（接受点击/选择文本），所以用 `.titled`（无标题栏装饰）
/// 但 becomesKeyOnlyIfNeeded，避免抢走当前焦点文本框的键盘焦点——用户想点的时候才成为 key。
@MainActor
final class ResultOverlay {
    static let shared = ResultOverlay()

    private var panel: NSPanel?

    /// 显示结果窗口。
    func show(answer: String) {
        // 已有窗口先关掉，重建内容
        hide()

        let size = NSSize(width: 460, height: 320)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Typeless Assistant"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.center()

        let hosting = NSHostingView(rootView: ResultOverlayView(answer: answer, onClose: { [weak self] in
            self?.hide()
        }))
        panel.contentView = hosting

        self.panel = panel
        panel.orderFrontRegardless()
        logger.info("Result overlay shown (\(answer.count) chars)")
    }

    /// 隐藏结果窗口。
    func hide() {
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        logger.info("Result overlay hidden")
    }
}
