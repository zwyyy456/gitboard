import Foundation
import Observation

@MainActor
@Observable
final class GitBoardModel {
    let projectStore = ProjectStore()
    let myWorkStore = MyWorkStore()

    var monitoringEnabled: Bool
    var monitoringIntervalMinutes: Int
    var quietStartHour: Int
    var quietEndHour: Int
    var monitoringStatus: String?

    private let projectMonitor = ProjectMonitor()
    private let notificationService = NotificationService.shared
    private var monitorTask: Task<Void, Never>?
    private var mutedProjectIDs: Set<String>
    private var snoozedItems: [String: Date]
    private var didStart = false

    var mutedProjectCount: Int { mutedProjectIDs.count }
    var myWorkProjects: [Project] {
        myWorkStore.followedProjects.compactMap { projectStore.followedProject(id: $0.id) }
    }
    var myWorkErrorMessage: String? {
        projectStore.followedProjectsErrorMessage ?? projectStore.operationErrorMessage
    }
    var attentionCount: Int {
        myWorkStore.attentionCount(
            in: myWorkProjects,
            currentUserLogin: projectStore.currentUserLogin
        )
    }

    init() {
        let defaults = UserDefaults.standard
        monitoringEnabled = defaults.bool(forKey: "monitoringEnabled")
        let interval = defaults.integer(forKey: "monitoringIntervalMinutes")
        monitoringIntervalMinutes = interval == 0 ? 15 : interval
        quietStartHour = defaults.object(forKey: "quietStartHour") == nil
            ? 22
            : defaults.integer(forKey: "quietStartHour")
        quietEndHour = defaults.object(forKey: "quietEndHour") == nil
            ? 8
            : defaults.integer(forKey: "quietEndHour")
        mutedProjectIDs = Set(defaults.stringArray(forKey: "mutedProjectIDs") ?? [])
        let snoozed = defaults.dictionary(forKey: "snoozedItems") as? [String: Double] ?? [:]
        snoozedItems = snoozed.mapValues(Date.init(timeIntervalSince1970:))
    }

    func start() async {
        guard didStart == false else { return }
        didStart = true
        if projectStore.currentUserLogin == nil {
            await projectStore.loadProjects()
        }
        myWorkStore.activate(accountLogin: projectStore.currentUserLogin)
        if myWorkStore.followedProjects.isEmpty == false {
            await refreshMyWork()
        } else {
            projectStore.setFollowedProjects([])
        }
        if monitoringEnabled {
            guard await notificationService.checkPermission() else {
                monitoringEnabled = false
                UserDefaults.standard.set(false, forKey: "monitoringEnabled")
                monitoringStatus = "Notifications are disabled in System Settings."
                return
            }
            await restartMonitoring()
        }
    }

    func setMonitoringEnabled(_ enabled: Bool) async {
        if enabled {
            guard await notificationService.requestPermission() else {
                monitoringEnabled = false
                monitoringStatus = "Notification permission was not granted."
                UserDefaults.standard.set(false, forKey: "monitoringEnabled")
                return
            }
        }
        monitoringEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "monitoringEnabled")
        if enabled {
            if projectStore.currentUserLogin == nil {
                await projectStore.loadProjects()
            }
            myWorkStore.activate(accountLogin: projectStore.currentUserLogin)
            await restartMonitoring()
        } else {
            monitorTask?.cancel()
            monitorTask = nil
            await projectMonitor.stop()
            monitoringStatus = "Monitoring is off."
        }
    }

    func updateMonitoringSchedule(
        intervalMinutes: Int? = nil,
        quietStartHour: Int? = nil,
        quietEndHour: Int? = nil
    ) async {
        let defaults = UserDefaults.standard
        if let intervalMinutes {
            monitoringIntervalMinutes = intervalMinutes
            defaults.set(intervalMinutes, forKey: "monitoringIntervalMinutes")
        }
        if let quietStartHour {
            self.quietStartHour = quietStartHour
            defaults.set(quietStartHour, forKey: "quietStartHour")
        }
        if let quietEndHour {
            self.quietEndHour = quietEndHour
            defaults.set(quietEndHour, forKey: "quietEndHour")
        }
        if monitoringEnabled { await restartMonitoring() }
    }

    func toggleFollowing(_ project: Project) async {
        myWorkStore.toggleFollowing(project)
        if myWorkStore.isFollowing(project.id) {
            await refreshMyWork()
        } else {
            projectStore.setFollowedProjects(myWorkStore.followedProjects)
        }
        if monitoringEnabled { await restartMonitoring() }
    }

    func stopFollowing(_ reference: FollowedProject) async {
        myWorkStore.stopFollowing(reference)
        projectStore.setFollowedProjects(myWorkStore.followedProjects)
        if monitoringEnabled { await restartMonitoring() }
    }

    func activateMyWork(accountLogin: String?) async {
        let oldProjects = myWorkStore.followedProjects.map(\.id)
        myWorkStore.activate(accountLogin: accountLogin)
        if myWorkStore.followedProjects.isEmpty {
            projectStore.setFollowedProjects([])
        } else if oldProjects != myWorkStore.followedProjects.map(\.id) {
            await refreshMyWork()
        }
        if monitoringEnabled, oldProjects != myWorkStore.followedProjects.map(\.id) {
            await restartMonitoring()
        }
    }

    func refreshMyWork() async {
        await projectStore.refreshFollowedProjects(myWorkStore.followedProjects)
    }

    func myWorkItems(for filter: MyWorkFilter) -> [MyWorkItem] {
        myWorkStore.items(
            for: filter,
            in: myWorkProjects,
            currentUserLogin: projectStore.currentUserLogin
        )
    }

    func openProject(_ project: Project) async {
        await projectStore.openProject(FollowedProject(project: project))
    }

    func updateMyWorkField(
        on item: MyWorkItem,
        field: ProjectField,
        value: ProjectFieldValue?
    ) async {
        _ = await projectStore.updateField(
            on: item.item,
            in: item.project.id,
            field: field,
            value: value
        )
    }

    func archiveMyWorkItem(_ item: MyWorkItem) async {
        _ = await projectStore.archiveItem(item.item, in: item.project.id)
    }

    func handleNotificationAction(_ action: ProjectNotificationAction) async -> URL? {
        let key = "\(action.projectID):\(action.itemID)"
        switch action.kind {
        case .open:
            return action.itemURL.flatMap(URL.init(string:))
        case .moveToDone:
            guard let fieldID = action.statusFieldID,
                  let optionID = action.doneOptionID else {
                monitoringStatus = "This Project has no recognizable Done status."
                return nil
            }
            _ = await projectStore.moveItemToStatus(
                projectID: action.projectID,
                itemID: action.itemID,
                fieldID: fieldID,
                optionID: optionID
            )
        case .snooze:
            snoozedItems[key] = Date().addingTimeInterval(60 * 60)
            saveSnoozedItems()
        case .muteProject:
            mutedProjectIDs.insert(action.projectID)
            UserDefaults.standard.set(Array(mutedProjectIDs), forKey: "mutedProjectIDs")
        }
        return nil
    }

    func clearMutedProjects() {
        mutedProjectIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: "mutedProjectIDs")
    }

    private func restartMonitoring() async {
        monitorTask?.cancel()
        monitorTask = nil
        await projectMonitor.stop()

        guard monitoringEnabled else { return }
        guard let login = projectStore.currentUserLogin else {
            monitoringStatus = "Waiting for GitHub authentication."
            return
        }
        let projects = myWorkStore.followedProjects
        guard projects.isEmpty == false else {
            monitoringStatus = "Follow a Project to start monitoring."
            return
        }

        let policy = MonitoringPolicy(
            interval: .seconds(monitoringIntervalMinutes * 60),
            quietStartHour: quietStartHour,
            quietEndHour: quietEndHour
        )
        let events = await projectMonitor.events(
            for: projects,
            currentUserLogin: login,
            policy: policy
        )
        monitoringStatus = "Monitoring \(projects.count) Project\(projects.count == 1 ? "" : "s")."
        monitorTask = Task { [weak self] in
            for await event in events {
                guard Task.isCancelled == false else { return }
                await self?.handleMonitorEvent(event)
            }
        }
    }

    private func handleMonitorEvent(_ event: ProjectMonitorEvent) async {
        do {
            switch event {
            case .snapshots(let projects):
                projectStore.applyMonitoredSnapshots(projects)
            case .change(let change):
                guard shouldNotify(change) else { return }
                try await notificationService.send(change)
            case .digest(let changes):
                let changes = changes.filter(shouldNotify)
                try await notificationService.sendDigest(changes)
            case .rateLimited(let resetDescription):
                monitoringStatus = resetDescription.map {
                    "Monitoring paused by GitHub rate limit. Try again \($0)."
                } ?? "Monitoring paused by GitHub rate limit."
            case .failed(let message):
                monitoringStatus = "Monitoring error: \(message)"
            }
        } catch {
            monitoringStatus = "Notification delivery failed: \(error.localizedDescription)"
        }
    }

    private func shouldNotify(_ change: ProjectChange) -> Bool {
        guard mutedProjectIDs.contains(change.projectID) == false else { return false }
        let key = "\(change.projectID):\(change.itemID)"
        if let until = snoozedItems[key] {
            if until > Date() { return false }
            snoozedItems[key] = nil
            saveSnoozedItems()
        }
        return true
    }

    private func saveSnoozedItems() {
        UserDefaults.standard.set(
            snoozedItems.mapValues(\.timeIntervalSince1970),
            forKey: "snoozedItems"
        )
    }
}
