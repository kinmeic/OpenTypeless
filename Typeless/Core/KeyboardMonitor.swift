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
}

// MARK: - KeyboardMonitor

/// Global keyboard listener using CGEventTap.
/// Matches configured shortcuts and fires callbacks.
/// Requires Input Monitoring permission.
@MainActor
final class KeyboardMonitor: ObservableObject {
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
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<KeyboardMonitor>.fromOpaque(info).takeUnretainedValue()
                // CGEventTap callback runs on a dedicated thread, dispatch to main actor
                Task { @MainActor in
                    me.handleEvent(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
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

    private func handleEvent(type: CGEventType, event: CGEvent) {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        switch type {
        case .keyDown:
            pressingKeyCodes.insert(keyCode)
            checkMatch(keyCode: keyCode)

        case .keyUp:
            pressingKeyCodes.remove(keyCode)

        case .flagsChanged:
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            pressingModifiers = flags
            // Some shortcuts are modifier-only (e.g. just Option), check those too
            if pressingKeyCodes.isEmpty {
                checkMatch(keyCode: nil)
            }

        default:
            break
        }
    }

    private func checkMatch(keyCode: Int?) {
        for shortcut in shortcuts {
            let targetModifiers = NSEvent.ModifierFlags(rawValue: UInt(shortcut.modifierFlags))
            let targetKeyCode = shortcut.keyCode

            let modifiersMatch = pressingModifiers.contains(targetModifiers)
            let keyMatch = keyCode.map { $0 == targetKeyCode } ?? (targetKeyCode == 0)

            guard modifiersMatch && keyMatch else { continue }

            let keyName = KeyCodes.name(for: targetKeyCode) ?? "\(targetKeyCode)"
            let shortcutString = shortcutDisplay(modifiers: targetModifiers, key: keyName)
            let event = ShortcutEvent(
                keyCode: targetKeyCode,
                keyName: keyName,
                modifiers: pressingModifiers,
                matchedShortcut: shortcutString
            )
            onShortcut?(event)
            return // match one at a time
        }
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
