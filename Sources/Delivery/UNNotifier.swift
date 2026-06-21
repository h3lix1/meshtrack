// UNNotifier — macOS Notification Center delivery (SPEC §2.6, default channel).
//
// Requires a real app bundle + user authorization, so it is exercised by the
// SwiftUI app, not headless tests. Compiles everywhere; only `send` touches the
// system framework.

import RuleEngine
import UserNotifications

public struct UNNotifier: Notifier {
    public init() {}

    /// Request notification authorization once at app startup.
    public static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    public func send(_ notification: AlertNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "\(notification.alertType.rawValue)-\(notification.nodeNum)-\(notification.isResolution)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
