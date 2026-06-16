import Foundation
import ApplicationServices
import AppKit
import CoreGraphics
import os.log

private let logger = Logger(subsystem: "com.opentypeless.app", category: "context")

/// C 流程的上下文采集：只读取当前焦点上下文中的选中文本。
///
/// 只使用 Accessibility API，不读取或改写剪贴板。
@MainActor
final class ContextCollector {
    struct CollectedContext {
        var selectedText: String?

        var isEmpty: Bool {
            selectedText?.isEmpty ?? true
        }
    }

    func collect() async -> CollectedContext {
        var ctx = CollectedContext()

        if let axText = axSelectedText() {
            ctx.selectedText = axText
            logger.info("Selected text via AX: \(axText.count) chars")
        } else if let copiedText = await selectedTextViaTemporaryCopy() {
            ctx.selectedText = copiedText
            logger.info("Selected text via temporary copy: \(copiedText.count) chars")
        } else if AXIsProcessTrusted() {
            logger.warning("No selected text available through AX")
        } else {
            logger.error("Accessibility permission not granted")
        }

        return ctx
    }

    // MARK: - AX Selected Text (no side effects)

    /// 通过 AX API 读焦点元素的选中文本。无副作用。
    private func axSelectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        guard let focused = focusedElement() else { return nil }

        for element in candidateElements(startingAt: focused) {
            if let selected = selectedTextAttribute(from: element) {
                return selected
            }
            if let selected = selectedTextRange(from: element) {
                return selected
            }
            if let selected = selectedTextRanges(from: element) {
                return selected
            }
            if let selected = selectedTextMarkerRange(from: element) {
                return selected
            }
        }

        return nil
    }

    private func focusedElement() -> AXUIElement? {
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success else {
            return nil
        }
        guard let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return (focusedRef as! AXUIElement)
    }

    private func candidateElements(startingAt element: AXUIElement) -> [AXUIElement] {
        var elements: [AXUIElement] = []
        var current: AXUIElement? = element

        for _ in 0..<8 {
            guard let candidate = current else { break }
            elements.append(candidate)

            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                candidate,
                kAXParentAttribute as CFString,
                &parentRef
            ) == .success else {
                break
            }
            guard let parentRef, CFGetTypeID(parentRef) == AXUIElementGetTypeID() else {
                break
            }
            current = (parentRef as! AXUIElement)
        }

        return elements
    }

    private func selectedTextAttribute(from element: AXUIElement) -> String? {
        var selectedTextRaw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextRaw
        )

        guard result == .success, let selectedText = selectedTextRaw as? String else { return nil }
        return nonEmpty(selectedText)
    }

    private func selectedTextRange(from element: AXUIElement) -> String? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success, let rangeValue = rangeRef else { return nil }

        return stringForRange(rangeValue, from: element)
    }

    private func selectedTextRanges(from element: AXUIElement) -> String? {
        var rangesRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangesAttribute as CFString,
            &rangesRef
        ) == .success, let ranges = rangesRef as? [CFTypeRef] else { return nil }

        let parts = ranges.compactMap { stringForRange($0, from: element) }
        return nonEmpty(parts.joined(separator: "\n"))
    }

    private func stringForRange(_ rangeValue: CFTypeRef, from element: AXUIElement) -> String? {
        var stringRef: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &stringRef
        )

        guard result == .success, let selectedText = stringRef as? String else { return nil }
        return nonEmpty(selectedText)
    }

    private func selectedTextMarkerRange(from element: AXUIElement) -> String? {
        let markerRangeAttribute = "AXSelectedTextMarkerRange" as CFString
        let stringForMarkerRangeAttribute = "AXStringForTextMarkerRange" as CFString

        var markerRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            markerRangeAttribute,
            &markerRangeRef
        ) == .success, let markerRange = markerRangeRef else { return nil }

        var stringRef: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            stringForMarkerRangeAttribute,
            markerRange,
            &stringRef
        )

        guard result == .success, let selectedText = stringRef as? String else { return nil }
        return nonEmpty(selectedText)
    }

    private func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    // MARK: - Copy Fallback

    /// AX does not expose normal text selections in many apps such as browsers and code editors.
    /// Fall back to a temporary copy, then restore the user's clipboard.
    private func selectedTextViaTemporaryCopy() async -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let pasteboard = NSPasteboard.general
        let snapshot = savePasteboard(pasteboard)
        let beforeChangeCount = pasteboard.changeCount

        // Let the shortcut keys that started recording finish releasing before posting Cmd+C.
        try? await Task.sleep(for: .milliseconds(180))
        simulateCmdC()
        try? await Task.sleep(for: .milliseconds(160))

        let copiedText: String?
        if pasteboard.changeCount != beforeChangeCount {
            copiedText = nonEmpty(pasteboard.string(forType: .string) ?? "")
        } else {
            copiedText = nil
        }
        restorePasteboard(snapshot, to: pasteboard)
        return copiedText
    }

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
        let items = snapshot.items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        if items.isEmpty == false {
            pasteboard.writeObjects(items)
        }
    }

    private func simulateCmdC() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let source else {
            logger.error("CGEventSource creation failed")
            return
        }

        let cmdKeyCode: CGKeyCode = 0x37
        let cKeyCode: CGKeyCode = 0x08

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: true),
              let cDown = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true),
              let cUp = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: false)
        else {
            logger.error("CGEvent creation failed")
            return
        }

        cDown.flags = .maskCommand
        cUp.flags = .maskCommand

        cmdDown.post(tap: .cghidEventTap)
        cDown.post(tap: .cghidEventTap)
        cUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
    }
}
