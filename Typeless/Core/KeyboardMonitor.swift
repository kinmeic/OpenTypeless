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
    private let healthCheckInterval: TimeInterval = 5
    private let installRetryInterval: TimeInterval = 30
    private let installFailureLogInterval: TimeInterval = 30

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthCheckTimer: Timer?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var onShortcut: ((ShortcutEvent) -> Void)?
    private var isMonitoring = false
    private var lastInstallAttemptTime = Date.distantPast
    private var lastInstallFailureLogTime = Date.distantPast

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
        isMonitoring = true
        reset()

        let installed = installEventTap(reason: "start", force: true)
        startHealthCheck()
        startActivationRecovery()
        if installed {
            logger.info("Keyboard monitor started")
        } else {
            logger.info("Keyboard monitor waiting for Input Monitoring permission")
        }
    }

    func stop() {
        isMonitoring = false
        stopHealthCheck()
        stopActivationRecovery()
        teardownEventTap()
        onShortcut = nil
        reset()
        logger.info("Keyboard monitor stopped")
    }

    func update(_ config: ShortcutsConfig) {
        shortcuts = [config.a, config.b, config.c]
    }

    func reset() {
        pressingModifiers = []
        pressingKeyCodes.removeAll()
    }

    // MARK: - Event Tap Lifecycle

    private var eventMask: CGEventMask {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        return CGEventMask(mask)
    }

    @discardableResult
    private func installEventTap(reason: String, force: Bool) -> Bool {
        let now = Date()
        if force == false && now.timeIntervalSince(lastInstallAttemptTime) < installRetryInterval {
            return false
        }
        lastInstallAttemptTime = now
        teardownEventTap()

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
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
            logEventTapInstallFailure(reason: reason)
            return false
        }

        self.eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lastInstallAttemptTime = .distantPast
        lastInstallFailureLogTime = .distantPast
        logger.info("Keyboard event tap installed: \(reason, privacy: .public)")
        return true
    }

    private func teardownEventTap() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    private func startHealthCheck() {
        stopHealthCheck()

        let timer = Timer(timeInterval: healthCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.verifyEventTapHealth()
            }
        }
        healthCheckTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    private func verifyEventTapHealth() {
        guard isMonitoring else { return }

        guard let tap = eventTap else {
            restartEventTap(reason: "missing event tap", force: false)
            return
        }

        guard CFMachPortIsValid(tap) else {
            restartEventTap(reason: "invalid event tap", force: true)
            return
        }

        if CGEvent.tapIsEnabled(tap: tap) == false {
            enableCurrentEventTap(reason: "health check found disabled event tap")
        }
    }

    private func enableCurrentEventTap(reason: String) {
        guard isMonitoring else { return }

        guard let tap = eventTap, CFMachPortIsValid(tap) else {
            restartEventTap(reason: reason, force: true)
            return
        }

        CGEvent.tapEnable(tap: tap, enable: true)
        logger.warning("Keyboard event tap re-enabled: \(reason, privacy: .public)")

        if CGEvent.tapIsEnabled(tap: tap) == false {
            restartEventTap(reason: "\(reason); re-enable failed", force: true)
        }
    }

    private func restartEventTap(reason: String, force: Bool) {
        guard isMonitoring else { return }
        reset()
        logger.warning("Restarting keyboard event tap: \(reason, privacy: .public)")
        _ = installEventTap(reason: reason, force: force)
    }

    private func startActivationRecovery() {
        stopActivationRecovery()
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recoverEventTapAfterActivation()
            }
        }
    }

    private func stopActivationRecovery() {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
            self.didBecomeActiveObserver = nil
        }
    }

    private func recoverEventTapAfterActivation() {
        guard isMonitoring else { return }
        guard let tap = eventTap, CFMachPortIsValid(tap) else {
            restartEventTap(reason: "app became active", force: true)
            return
        }

        if CGEvent.tapIsEnabled(tap: tap) == false {
            enableCurrentEventTap(reason: "app became active")
        }
    }

    private func logEventTapInstallFailure(reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastInstallFailureLogTime) >= installFailureLogInterval else { return }
        lastInstallFailureLogTime = now
        logger.error("CGEvent.tapCreate returned nil (\(reason, privacy: .public)); Input Monitoring permission may be missing")
    }

    // MARK: - Event Handling

    /// Returns true when the original event should be swallowed.
    private func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout:
            enableCurrentEventTap(reason: "disabled by timeout")
            return false
        case .tapDisabledByUserInput:
            enableCurrentEventTap(reason: "disabled by user input")
            return false
        default:
            break
        }

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
