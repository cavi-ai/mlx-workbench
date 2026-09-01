import Foundation
import UserNotifications

// MARK: - AlertNotifier
//
// Notification Center delivery for watch alerts (spec 08 follow-up). Thin
// glue: the WatchCoordinator's injectable `notify` is the tested surface;
// this only translates an alert into a system notification. When permission
// is denied or unavailable, alerts remain in-app — silent by design.

enum AlertNotifier {
    static func post(_ alert: WatchAlert) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            center.add(UNNotificationRequest(
                identifier: alert.id.uuidString,
                content: content,
                trigger: nil
            ))
        }
    }
}
