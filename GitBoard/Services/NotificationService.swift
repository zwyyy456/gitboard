import Foundation
import UserNotifications

enum ProjectNotificationActionKind: Sendable {
    case open
    case moveToDone
    case snooze
    case muteProject
}

struct ProjectNotificationAction: Sendable {
    let kind: ProjectNotificationActionKind
    let projectID: String
    let itemID: String
    let itemURL: String?
    let statusFieldID: String?
    let doneOptionID: String?
}

actor NotificationService {
    static let shared = NotificationService()

    private let delegate = ProjectNotificationDelegate()

    private init() {}

    func actions() -> AsyncStream<ProjectNotificationAction> {
        configureCategories()
        UNUserNotificationCenter.current().delegate = delegate
        return delegate.actions()
    }

    func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
        } catch {
            return false
        }
    }

    func checkPermission() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    func send(_ change: ProjectChange) async throws {
        guard await checkPermission() else { return }

        let content = UNMutableNotificationContent()
        content.title = change.projectTitle
        content.body = notificationBody(for: change)
        content.sound = .default
        content.categoryIdentifier = "PROJECT_CHANGE"
        content.threadIdentifier = change.projectID
        content.userInfo = notificationPayload(for: change)

        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: change.id.uuidString,
                content: content,
                trigger: nil
            )
        )
    }

    func sendDigest(_ changes: [ProjectChange]) async throws {
        guard changes.isEmpty == false, await checkPermission() else { return }
        let projects = Set(changes.map(\.projectTitle))
        let content = UNMutableNotificationContent()
        content.title = "GitBoard Summary"
        content.body = "\(changes.count) changes across \(projects.count) followed project\(projects.count == 1 ? "" : "s")."
        content.sound = .default

        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "digest-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
        )
    }

    private func configureCategories() {
        let actions = [
            UNNotificationAction(identifier: "OPEN", title: "Open", options: [.foreground]),
            UNNotificationAction(identifier: "MOVE_DONE", title: "Move to Done"),
            UNNotificationAction(identifier: "SNOOZE", title: "Snooze 1 Hour"),
            UNNotificationAction(
                identifier: "MUTE_PROJECT",
                title: "Mute Project",
                options: [.destructive]
            )
        ]
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: "PROJECT_CHANGE",
                actions: actions,
                intentIdentifiers: []
            )
        ])
    }

    private func notificationBody(for change: ProjectChange) -> String {
        switch change.kind {
        case .status(let from, let to):
            return "\(change.itemTitle): \(from ?? "No Status") → \(to ?? "No Status")"
        case .assignedToMe:
            return "Assigned to you: \(change.itemTitle)"
        case .unassignedFromMe:
            return "Unassigned from you: \(change.itemTitle)"
        case .dueSoon:
            return "Due soon: \(change.itemTitle)"
        case .overdue:
            return "Overdue: \(change.itemTitle)"
        case .blocked:
            return "Blocked: \(change.itemTitle)"
        case .unblocked:
            return "Unblocked: \(change.itemTitle)"
        }
    }

    private func notificationPayload(for change: ProjectChange) -> [String: String] {
        var payload = ["projectID": change.projectID, "itemID": change.itemID]
        payload["itemURL"] = change.itemURL
        payload["statusFieldID"] = change.statusFieldID
        payload["doneOptionID"] = change.doneOptionID
        return payload
    }
}

private final class ProjectNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<ProjectNotificationAction>.Continuation?

    func actions() -> AsyncStream<ProjectNotificationAction> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let payload = response.notification.request.content.userInfo
        guard let projectID = payload["projectID"] as? String,
              let itemID = payload["itemID"] as? String else { return }

        let kind: ProjectNotificationActionKind
        switch response.actionIdentifier {
        case "MOVE_DONE": kind = .moveToDone
        case "SNOOZE": kind = .snooze
        case "MUTE_PROJECT": kind = .muteProject
        default: kind = .open
        }
        let action = ProjectNotificationAction(
            kind: kind,
            projectID: projectID,
            itemID: itemID,
            itemURL: payload["itemURL"] as? String,
            statusFieldID: payload["statusFieldID"] as? String,
            doneOptionID: payload["doneOptionID"] as? String
        )
        _ = lock.withLock { continuation?.yield(action) }
    }
}
