import Foundation
import UserNotifications

// MARK: - AlertNotifier
//
// Notification Center delivery for watch alerts (spec 08 follow-up) and
// workflow terminal-state outcomes (conversion finished/failed, verification
// passed/failed). Thin glue: the coordinators' injectable closures are the
// tested surfaces; this only translates an event into a system notification.
// When permission is denied or unavailable, alerts remain in-app — silent by
// design.

enum AlertNotifier {
    static func post(_ alert: WatchAlert) {
        post(title: alert.title, body: alert.body, identifier: alert.id.uuidString)
    }

    /// Conversion/verification outcome from a workflow's terminal-state
    /// transition (ModelWorkflowCoordinator.onTerminalState).
    static func post(workflowOutcome record: ConversionWorkflow) {
        let title: String
        switch record.state {
        case .verified: title = "Verification passed"
        case .verificationFailed: title = "Verification failed"
        case .completed: title = "Conversion finished"
        case .failed: title = "Conversion failed"
        default: return
        }
        let name = URL(fileURLWithPath: record.completedModelPath ?? record.sourcePath).lastPathComponent
        let detail = record.errorMessage ?? record.message ?? ""
        let body = detail.isEmpty ? name : "\(name) — \(detail)"
        post(
            title: title,
            body: body,
            identifier: "\(record.id.uuidString)-\(record.state.rawValue)"
        )
    }

    static func post(title: String, body: String, identifier: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            ))
        }
    }
}
