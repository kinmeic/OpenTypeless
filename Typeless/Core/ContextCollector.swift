import Foundation
import ApplicationServices
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
}
