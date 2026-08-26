import Foundation
import Observation

@MainActor
@Observable
final class MyWorkStore {
    private(set) var followedProjects: [FollowedProject]
    private(set) var snapshots: [String: Project] = [:]
    private(set) var filters: [MyWorkFilter]
    var isLoading = false
    var errorMessage: String?

    private let gitHubService = GitHubService.shared
    private var refreshGeneration = 0

    init() {
        followedProjects = Self.loadFollowedProjects()
        filters = Self.loadFilters()
    }

    func isFollowing(_ projectID: String) -> Bool {
        followedProjects.contains { $0.id == projectID }
    }

    func activate(accountLogin: String?) {
        guard let accountLogin else { return }
        let defaults = UserDefaults.standard
        if let storedLogin = defaults.string(forKey: "myWorkAccountLogin"),
           storedLogin.caseInsensitiveCompare(accountLogin) != .orderedSame {
            followedProjects = []
            snapshots = [:]
            saveFollowedProjects()
        }
        defaults.set(accountLogin, forKey: "myWorkAccountLogin")
    }

    func toggleFollowing(_ project: Project) async {
        if let index = followedProjects.firstIndex(where: { $0.id == project.id }) {
            followedProjects.remove(at: index)
            snapshots[project.id] = nil
            saveFollowedProjects()
        } else {
            let reference = FollowedProject(project: project)
            followedProjects.append(reference)
            saveFollowedProjects()
            await load(reference)
        }
    }

    func stopFollowing(_ reference: FollowedProject) {
        followedProjects.removeAll { $0.id == reference.id }
        snapshots[reference.id] = nil
        saveFollowedProjects()
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        errorMessage = nil
        defer {
            if generation == refreshGeneration {
                isLoading = false
            }
        }

        var loaded: [String: Project] = [:]
        do {
            for reference in followedProjects {
                try Task.checkCancellation()
                loaded[reference.id] = try await gitHubService.fetchProjectWithItems(
                    project: reference.projectSummary
                )
            }
            guard generation == refreshGeneration else { return }
            snapshots = loaded
        } catch is CancellationError {
            return
        } catch {
            guard generation == refreshGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func items(for filter: MyWorkFilter, currentUserLogin: String?) -> [MyWorkItem] {
        snapshots.values
            .flatMap { project in
                project.items.map { MyWorkItem(project: project, item: $0) }
            }
            .filter { filter.includes($0, currentUserLogin: currentUserLogin) }
            .sorted { $0.updatedDate > $1.updatedDate }
    }

    func attentionCount(currentUserLogin: String?) -> Int {
        let filters: [MyWorkFilter] = [.reviewRequested, .ciFailed, .due]
        return Set(filters.flatMap {
            items(for: $0, currentUserLogin: currentUserLogin).map(\.id)
        }).count
    }

    func applyMonitoredSnapshots(_ projects: [Project]) {
        snapshots = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
    }

    func updateField(
        on workItem: MyWorkItem,
        field: ProjectField,
        value: ProjectFieldValue?
    ) async -> Bool {
        errorMessage = nil
        do {
            try await gitHubService.updateItemField(
                projectId: workItem.project.id,
                itemId: workItem.item.id,
                fieldId: field.id,
                value: value
            )
            await reload(projectID: workItem.project.id)
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func archive(_ workItem: MyWorkItem) async -> Bool {
        errorMessage = nil
        do {
            try await gitHubService.archiveItem(
                projectId: workItem.project.id,
                itemId: workItem.item.id
            )
            snapshots[workItem.project.id]?.items.removeAll { $0.id == workItem.item.id }
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func moveItemToDone(
        projectID: String,
        itemID: String,
        fieldID: String,
        optionID: String
    ) async -> Bool {
        errorMessage = nil
        do {
            try await gitHubService.updateItemStatus(
                projectId: projectID,
                itemId: itemID,
                fieldId: fieldID,
                optionId: optionID
            )
            await reload(projectID: projectID)
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func setFilterVisible(_ filter: MyWorkFilter, visible: Bool) {
        if visible {
            guard filters.contains(filter) == false else { return }
            filters.append(filter)
        } else {
            guard filters.count > 1 else { return }
            filters.removeAll { $0 == filter }
        }
        saveFilters()
    }

    func moveFilter(_ filter: MyWorkFilter, offset: Int) {
        guard let index = filters.firstIndex(of: filter) else { return }
        let destination = index + offset
        guard filters.indices.contains(destination) else { return }
        filters.swapAt(index, destination)
        saveFilters()
    }

    private func load(_ reference: FollowedProject) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            snapshots[reference.id] = try await gitHubService.fetchProjectWithItems(
                project: reference.projectSummary
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reload(projectID: String) async {
        guard let reference = followedProjects.first(where: { $0.id == projectID }) else { return }
        do {
            snapshots[projectID] = try await gitHubService.fetchProjectWithItems(
                project: reference.projectSummary
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveFollowedProjects() {
        guard let data = try? JSONEncoder().encode(followedProjects) else { return }
        UserDefaults.standard.set(data, forKey: "followedProjects")
    }

    private func saveFilters() {
        UserDefaults.standard.set(filters.map(\.rawValue), forKey: "myWorkFilters")
    }

    private static func loadFollowedProjects() -> [FollowedProject] {
        guard let data = UserDefaults.standard.data(forKey: "followedProjects"),
              let projects = try? JSONDecoder().decode([FollowedProject].self, from: data) else {
            return []
        }
        return projects
    }

    private static func loadFilters() -> [MyWorkFilter] {
        guard let values = UserDefaults.standard.stringArray(forKey: "myWorkFilters") else {
            return MyWorkFilter.allCases
        }
        let filters = values.compactMap(MyWorkFilter.init(rawValue:))
        return filters.isEmpty ? MyWorkFilter.allCases : filters
    }
}
