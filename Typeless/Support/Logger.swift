import Foundation
import os.log

// MARK: - App Logger

struct AppLogger {
    private let logger: Logger

    init(category: String) {
        self.logger = Logger(subsystem: "com.typeless.app", category: category)
    }

    func info(_ message: String) {
        logger.info("\(message)")
    }

    func debug(_ message: String) {
        logger.debug("\(message)")
    }

    func error(_ message: String) {
        logger.error("\(message)")
    }

    func warning(_ message: String) {
        logger.warning("\(message)")
    }
}
