import Foundation
import AppKit
import ApplicationServices
import os.log

private let logger = Logger(subsystem: "com.typeless.app", category: "context")

/// C 流程的上下文采集：选中文本 / 剪贴板图片 / 剪贴板文字。
///
/// 参照 Typeless ContextHelper + InputHelper.getSelectedText。
/// 读选中文本优先用 AX API（无副作用），失败降级模拟 ⌘C（有副作用，需 save/restore 剪贴板）。
@MainActor
final class ContextCollector {
    struct CollectedContext {
        var selectedText: String?
        var clipboardText: String?
        var clipboardImage: Data?

        var isEmpty: Bool {
            (selectedText?.isEmpty ?? true)
                && (clipboardText?.isEmpty ?? true)
                && clipboardImage == nil
        }
    }

    func collect() async -> CollectedContext {
        var ctx = CollectedContext()

        // 1. 选中文本：优先 AX API（无副作用）
        if let axText = axSelectedText() {
            ctx.selectedText = axText
            logger.info("Selected text via AX: \(axText.count) chars")
        } else {
            // 降级：模拟 ⌘C 读剪贴板（有副作用，需 save/restore）
            if let copiedText = await selectedTextBySimulateCopy() {
                ctx.selectedText = copiedText
                logger.info("Selected text via ⌘C: \(copiedText.count) chars")
            }
        }

        // 2. 剪贴板文字
        ctx.clipboardText = NSPasteboard.general.string(forType: .string)

        // 3. 剪贴板图片
        ctx.clipboardImage = NSPasteboard.general.data(forType: .tiff)
            ?? NSPasteboard.general.data(forType: .png)

        return ctx
    }

    // MARK: - AX Selected Text (no side effects)

    /// 通过 AX API 读焦点元素的选中文本。无副作用。
    private func axSelectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success else {
            return nil
        }
        let focused = focusedRef as! AXUIElement

        var selectedTextRaw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            &selectedTextRaw
        )

        guard result == .success,
              let selectedText = selectedTextRaw as? String,
              selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return selectedText
    }

    // MARK: - Simulated ⌘C (has side effects, wrapped in save/restore)

    /// 模拟 ⌘C 读选中文本。有副作用（会污染剪贴板），必须 save/restore。
    private func selectedTextBySimulateCopy() async -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = savePasteboard(pasteboard)
        defer {
            // 延迟还原，确保 ⌘C 完成后再还原
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                restorePasteboard(snapshot, to: pasteboard)
            }
        }

        // 清空剪贴板，确保读到的是本次 ⌘C 的内容
        pasteboard.clearContents()

        // 模拟 ⌘C
        simulateCmdC()
        try? await Task.sleep(for: .milliseconds(200))

        // 读剪贴板
        let text = pasteboard.string(forType: .string)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil
    }

    // MARK: - Simulate ⌘C

    private func simulateCmdC() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let source else { return }

        let cmdKeyCode: CGKeyCode = 0x37
        let cKeyCode: CGKeyCode = 0x08

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: true),
              let cDown   = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true),
              let cUp     = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false),
              let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: false)
        else { return }

        cDown.flags = .maskCommand
        cUp.flags = .maskCommand

        cmdDown.post(tap: .cghidEventTap)
        cDown.post(tap: .cghidEventTap)
        cUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
    }

    // MARK: - Pasteboard Snapshot (same as TextInjector)

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
}

private extension NSPasteboardItem {
    func then(_ configure: (NSPasteboardItem) -> Void) -> NSPasteboardItem {
        configure(self)
        return self
    }
}
