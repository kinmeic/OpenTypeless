import Foundation
import ApplicationServices
import AppKit
import CoreGraphics
import os.log

private let logger = Logger(subsystem: "com.opentypeless.app", category: "injector")

/// 把文字注入到当前焦点文本框。
///
/// 通过剪贴板 + 模拟 ⌘V 插入到当前焦点位置。
///
/// 早期 AX `kAXValueAttribute` 直写会替换整个输入框内容；这里默认走粘贴路径，
/// 以保留目标 App 的光标、选区和已有文本。
@MainActor
final class TextInjector {
    /// 高层入口：写入剪贴板、模拟粘贴，然后恢复剪贴板。
    func insert(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            logger.warning("Insert skipped: empty text")
            return
        }

        await pasteInsert(trimmed)
    }

    // MARK: - Pasteboard + Simulated ⌘V

    /// 备份当前剪贴板 → 写入目标文字 → 模拟 ⌘V → 等待 → 还原剪贴板。
    /// 关键时序：restorePasteboard 必须在 paste 完成之后，否则粘贴读到的是还原后的旧内容。
    private func pasteInsert(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let snapshot = savePasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        simulateCmdV()

        // CGEventPost 没有粘贴完成回调；给慢应用留出读取剪贴板的时间。
        try? await Task.sleep(for: .milliseconds(350))

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
