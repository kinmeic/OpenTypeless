import Foundation

// MARK: - Pipeline Events

enum PipelinePhase: String {
    case idle, recording, processing
}

struct KeyEvent {
    let eventType: Int // 0=keyDown, 1=keyUp, 2=flagsChanged
    let keyName: String
    let keyCode: Int
    let modifiers: Int
    let matchedShortcut: String?
}

// MARK: - Placeholder Models for future modules

struct CollectedContext {
    var selectedText: String?
}

struct StreamEvent {
    enum Kind {
        case delta(String)
        case done
        case error(String)
    }
    let kind: Kind
}
