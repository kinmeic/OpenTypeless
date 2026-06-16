import Foundation
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.opentypeless.app", category: "notifications")

/// 管理本地通知的显示，用于向用户报告 Pipeline 错误。
@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published var lastErrorTitle: String?
    @Published var lastErrorMessage: String?

    private init() {
        requestAuthorization()
    }

    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                logger.error("Notification auth failed: \(error.localizedDescription)")
            } else {
                logger.info("Notification authorization: \(granted)")
            }
        }
    }

    /// 发送一条错误通知。
    func showError(title: String, message: String) {
        lastErrorTitle = title
        lastErrorMessage = message

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "opentypeless-error-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil // 立即显示
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    func clearError() {
        lastErrorTitle = nil
        lastErrorMessage = nil
    }
}
