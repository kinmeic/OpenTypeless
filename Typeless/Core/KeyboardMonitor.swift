import Cocoa
import Foundation
import CoreGraphics
import os.log

private let logger = Logger(subsystem: "com.opentypeless.app", category: "keyboard")

// MARK: - Shortcut Event

struct ShortcutEvent: Equatable {
    let keyCode: Int
    let keyName: String
    let modifiers: NSEvent.ModifierFlags
    let matchedShortcut: String
    let role: String
}

// MARK: - KeyboardMonitor

/// Global keyboard listener using CGEventTap.
/// Matches configured shortcuts and fires callbacks.
/// Requires Input Monitoring permission.
@MainActor
final class KeyboardMonitor: ObservableObject {
    private let shortcutModifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onShortcut: ((ShortcutEvent) -> Void)?

    var shortcuts: [ShortcutConfig] = [] {
        didSet { logger.info("Shortcuts updated: \(self.shortcuts.count) items") }
    }

    private var pressingModifiers: NSEvent.ModifierFlags = []
    private var pressingKeyCodes: Set<Int> = []

    deinit {
        // Deinit is nonisolated; event tap cleanup is handled by the OS on process exit.
        // For explicit cleanup, call stop() before releasing the reference.
    }

    // MARK: - Start / Stop

    func start(onShortcut: @escaping (ShortcutEvent) -> Void) {
        self.onShortcut = onShortcut

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<KeyboardMonitor>.fromOpaque(info).takeUnretainedValue()
                let shouldConsume = MainActor.assumeIsolated {
                    me.handleEvent(type: type, event: event)
                }
                return shouldConsume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap else {
            logger.error("CGEvent.tapCreate returned nil — Input Monitoring permission not granted")
            return
        }

        self.eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.info("Keyboard monitor started")
    }

    func stop() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        eventTap = nil
        onShortcut = nil
        logger.info("Keyboard monitor stopped")
    }

    func update(_ config: ShortcutsConfig) {
        shortcuts = [config.a, config.b, config.c]
    }

    func reset() {
        pressingModifiers = []
        pressingKeyCodes.removeAll()
    }

    // MARK: - Event Handling

    /// Returns true when the original event should be swallowed.
    private func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let normalizedFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            .intersection(shortcutModifierMask)
        pressingModifiers = normalizedFlags

        switch type {
        case .keyDown:
            let wasAlreadyPressed = pressingKeyCodes.contains(keyCode)
            pressingKeyCodes.insert(keyCode)
            if let match = matchedShortcutEvent(keyCode: keyCode) {
                if wasAlreadyPressed == false {
                    onShortcut?(match)
                }
                return true
            }

        case .keyUp:
            pressingKeyCodes.remove(keyCode)

        case .flagsChanged:
            // Some shortcuts are modifier-only (e.g. just Option), check those too
            if pressingKeyCodes.isEmpty {
                if let match = matchedShortcutEvent(keyCode: nil) {
                    onShortcut?(match)
                    return true
                }
            }

        default:
            break
        }
        return false
    }

    private func matchedShortcutEvent(keyCode: Int?) -> ShortcutEvent? {
        for shortcut in shortcuts {
            let targetModifiers = NSEvent.ModifierFlags(rawValue: UInt(shortcut.modifierFlags))
                .intersection(shortcutModifierMask)
            let targetKeyCode = shortcut.keyCode

            let modifiersMatch = pressingModifiers == targetModifiers
            let keyMatch = keyCode.map { $0 == targetKeyCode } ?? (targetKeyCode == 0)

            guard modifiersMatch && keyMatch else { continue }

            let keyName = KeyCodes.name(for: targetKeyCode) ?? "\(targetKeyCode)"
            let shortcutString = shortcutDisplay(modifiers: targetModifiers, key: keyName)
            return ShortcutEvent(
                keyCode: targetKeyCode,
                keyName: keyName,
                modifiers: pressingModifiers,
                matchedShortcut: shortcutString,
                role: shortcut.role
            )
        }
        return nil
    }

    private func shortcutDisplay(modifiers: NSEvent.ModifierFlags, key: String) -> String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("Command") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if !key.isEmpty { parts.append(key) }
        return parts.joined(separator: "+")
    }
}
