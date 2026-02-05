import Foundation
import UserNotifications

actor NotificationService {
    static let shared = NotificationService()

    private var isAuthorized = false

    private init() {}

    func requestPermission() async {
        let center = UNUserNotificationCenter.current()

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
        } catch {
            print("Notification permission error: \(error)")
            isAuthorized = false
        }
    }

    func checkPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
        return isAuthorized
    }

    func sendStatusChangeNotification(itemTitle: String, fromStatus: String, toStatus: String) async {
        if !isAuthorized {
            let hasPermission = await checkPermission()
            if !hasPermission {
                return
            }
        }

        let content = UNMutableNotificationContent()
        content.title = "Task Status Changed"
        content.body = "\"\(itemTitle)\" moved from \(fromStatus) to \(toStatus)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("Failed to send notification: \(error)")
        }
    }

    func sendProjectUpdateNotification(projectTitle: String, changedCount: Int) async {
        if !isAuthorized {
            let hasPermission = await checkPermission()
            if !hasPermission {
                return
            }
        }

        let content = UNMutableNotificationContent()
        content.title = "Project Updated"
        content.body = "\(changedCount) item(s) changed in \(projectTitle)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("Failed to send notification: \(error)")
        }
    }
}
