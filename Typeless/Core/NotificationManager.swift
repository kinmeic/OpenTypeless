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

    private init() {}

    func requestAuthorizationIfNeeded() {
        guard AppSettings.shared.enableSystemNotifications else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            Self.requestAuthorization()
        }
    }

    nonisolated private static func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                logger.error("Notification auth failed: \(error.localizedDescription)")
            } else {
                logger.info("Notification authorization: \(granted)")
            }
            completion?(granted)
        }
    }

    /// 发送一条错误通知。
    func showError(title: String, message: String) {
        lastErrorTitle = title
        lastErrorMessage = message

        guard AppSettings.shared.enableSystemNotifications else {
            logger.info("System notification skipped because notifications are disabled")
            return
        }

        postNotification(title: title, message: message)
    }

    private func postNotification(title: String, message: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Self.addNotification(title: title, message: message)
            case .notDetermined:
                Self.requestAuthorization { granted in
                    guard granted else { return }
                    Self.addNotification(title: title, message: message)
                }
            case .denied:
                logger.warning("System notification skipped because authorization is denied")
            @unknown default:
                logger.warning("System notification skipped because authorization status is unknown")
            }
        }
    }

    nonisolated private static func addNotification(title: String, message: String) {
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
