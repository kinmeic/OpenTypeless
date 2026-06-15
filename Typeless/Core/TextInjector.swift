import Foundation
import ApplicationServices
import AppKit
import CoreGraphics
import os.log

private let logger = Logger(subsystem: "com.typeless.app", category: "injector")

/// 把文字注入到当前焦点文本框。
///
/// 两条路径（同 Typeless InputHelper）：
/// - 路径 A（优先）：AX API 直写 `kAXValueAttribute`，对原生 App / Electron 友好。
/// - 路径 B（兜底）：剪贴板 + 模拟 ⌘V，兼容任意支持粘贴的应用。
///
/// 两条路径都需要 Accessibility 权限。
@MainActor
final class TextInjector {
    /// 高层入口：自动选路径 A，失败降级 B。
    func insert(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            logger.warning("Insert skipped: empty text")
            return
        }

        // 路径 A：AX API 直写
        if axInsert(trimmed) {
            logger.info("Inserted via AX API (\(trimmed.count) chars)")
            return
        }

        // 路径 B：剪贴板 + 模拟 ⌘V
        logger.info("AX insert failed, falling back to pasteboard + ⌘V")
        await pasteInsert(trimmed)
    }

    // MARK: - Path A: AX API Direct Write

    /// 通过 Accessibility API 直接设置焦点元素的 value。
    /// 返回 true 表示成功（AXUIElement 响应 kAXValueAttribute）。
    private func axInsert(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission not granted")
            return false
        }

        let focusedElement: AXUIElement?
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success {
            focusedElement = (focusedRef as! AXUIElement)
        } else {
            focusedElement = nil
        }

        guard let focused = focusedElement else {
            logger.warning("No focused AXUIElement found")
            return false
        }

        // 尝试直接设值
        let result = AXUIElementSetAttributeValue(
            focused,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        )
        if result == .success {
            return true
        }

        logger.warning("AX setAttribute failed: \(result.rawValue)")
        return false
    }

    // MARK: - Path B: Pasteboard + Simulated ⌘V

    /// 备份当前剪贴板 → 写入目标文字 → 模拟 ⌘V → 等待 → 还原剪贴板。
    /// 关键时序：restorePasteboard 必须在 paste 完成之后，否则粘贴读到的是还原后的旧内容。
    private func pasteInsert(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let snapshot = savePasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        simulateCmdV()

        // 双保险等待粘贴完成（参照 Typeless：PasteDone 回调 + setTimeout(100ms)）
        try? await Task.sleep(for: .milliseconds(150))

        restorePasteboard(snapshot, to: pasteboard)
        logger.info("Inserted via pasteboard+⌘V and restored clipboard (\(text.count) chars)")
    }

    // MARK: - Pasteboard Snapshot

    /// 备份剪贴板全部内容（types + data），用于精确还原。
    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private func savePasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            })
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    private func restorePasteboard(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = snapshot.items.map { dict in
            NSPasteboardItem().then { item in
                for (type, data) in dict {
                    item.setData(data, forType: type)
                }
            }
        }
        if items.isEmpty == false {
            pasteboard.writeObjects(items)
        }
    }

    // MARK: - Simulate ⌘V

    /// 模拟按下并释放 ⌘V。
    private func simulateCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let source else {
            logger.error("CGEventSource creation failed")
            return
        }

        let cmdKeyCode: CGKeyCode = 0x37  // Command
        let vKeyCode: CGKeyCode = 0x09    // V

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: true),
              let vDown   = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let vUp     = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false),
              let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: false)
        else {
            logger.error("CGEvent creation failed")
            return
        }

        // V 键事件带 Command 修饰符
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        cmdDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
    }
}

// MARK: - Then Helper (small functional convenience)

private extension NSPasteboardItem {
    func then(_ configure: (NSPasteboardItem) -> Void) -> NSPasteboardItem {
        configure(self)
        return self
    }
}
