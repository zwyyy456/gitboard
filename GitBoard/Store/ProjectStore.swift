import Foundation
import SwiftUI

@MainActor
@Observable
final class ProjectStore {
    var sessionState: GitHubSessionState = .checking
    var owners: [ProjectOwner] = []
    var projects: [Project] = []
    var selectedOwnerId: String? {
        didSet {
            UserDefaults.standard.set(selectedOwnerId, forKey: "selectedOwnerId")
        }
    }
    var selectedProjectId: String? {
        didSet {
            UserDefaults.standard.set(selectedProjectId, forKey: "selectedProjectId")
        }
    }

    // nil means "All", otherwise filter by status name
    var selectedStatusFilter: String? {
        didSet {
            UserDefaults.standard.set(selectedStatusFilter, forKey: "selectedStatusFilter")
        }
    }

    var isLoading = false
    var error: Error?
    var operationErrorMessage: String?
    var lastUpdated: Date?
    var currentUserLogin: String?
    var isShowingCachedData = false

    private var pollingTask: Task<Void, Never>?
    private var catalogGeneration = 0
    private var projectGeneration = 0
    private var didRestoreCache = false
    private var cachedAccountLogin: String?

    private let notificationService = NotificationService.shared
    private let gitHubService = GitHubService.shared
    private let projectCache = ProjectCache()

    var selectedProject: Project? {
        guard let id = selectedProjectId else { return nil }
        return projects.first { $0.id == id }
    }

    var selectedOwner: ProjectOwner? {
        guard let id = selectedOwnerId else { return nil }
        return owners.first { $0.id == id }
    }

    var pollInterval: TimeInterval = 45

    var filteredItems: [ProjectItem] {
        guard let project = selectedProject else { return [] }
        guard let filter = selectedStatusFilter else { return project.items }
        return project.items.filter { $0.status == filter }
    }

    var repositorySuggestions: [String] {
        guard let project = selectedProject else { return [] }
        return Array(Set(project.items.compactMap(\.repositoryName))).sorted()
    }

    init() {
        selectedOwnerId = UserDefaults.standard.string(forKey: "selectedOwnerId")
        selectedProjectId = UserDefaults.standard.string(forKey: "selectedProjectId")
        selectedStatusFilter = UserDefaults.standard.string(forKey: "selectedStatusFilter")
    }

    func loadProjects() async {
        await restoreCacheIfNeeded()
        catalogGeneration += 1
        let generation = catalogGeneration
        isLoading = true
        error = nil
        sessionState = .checking

        let session = await gitHubService.inspectSession()
        guard generation == catalogGeneration else { return }
        sessionState = session

        guard case .ready(let account) = session else {
            isLoading = false
            if isShowingCachedData {
                error = nil
                operationErrorMessage = cachedDataMessage(for: session)
            } else {
                error = sessionError(for: session)
            }
            return
        }

        if let cachedAccountLogin, cachedAccountLogin != account.login {
            owners = []
            projects = []
            selectedOwnerId = nil
            selectedProjectId = nil
            selectedStatusFilter = nil
            isShowingCachedData = false
        }
        currentUserLogin = account.login

        do {
            let loadedOwners = try await gitHubService.fetchOwners()
            guard generation == catalogGeneration else { return }
            owners = loadedOwners

            let owner = loadedOwners.first { $0.id == selectedOwnerId } ?? loadedOwners.first
            guard let owner else {
                projects = []
                selectedOwnerId = nil
                selectedProjectId = nil
                isLoading = false
                return
            }
            selectedOwnerId = owner.id
            await loadProjects(for: owner, generation: generation)
        } catch is CancellationError {
            return
        } catch {
            guard generation == catalogGeneration else { return }
            self.error = error
            isLoading = false
        }
    }

    func loadProjectDetails(id: String) async {
        projectGeneration += 1
        let generation = projectGeneration

        guard let project = projects.first(where: { $0.id == id }) else { return }
        do {
            let detailedProject = try await gitHubService.fetchProjectWithItems(project: project)
            guard generation == projectGeneration, selectedProjectId == id else { return }

            if let index = projects.firstIndex(where: { $0.id == id }) {
                let oldItems = projects[index].items
                await detectStatusChanges(oldItems: oldItems, newItems: detailedProject.items)

                projects[index] = detailedProject
            }

            lastUpdated = Date()
            isShowingCachedData = false
            operationErrorMessage = nil
            await persistCache()
        } catch is CancellationError {
            return
        } catch {
            guard generation == projectGeneration, selectedProjectId == id else { return }
            if isShowingCachedData {
                operationErrorMessage = "Showing cached data because GitHub refresh failed: \(error.localizedDescription)"
            } else {
                self.error = error
            }
        }
    }

    func selectOwner(_ owner: ProjectOwner) async {
        guard owner.id != selectedOwnerId else { return }
        catalogGeneration += 1
        let generation = catalogGeneration
        selectedOwnerId = owner.id
        selectedProjectId = nil
        selectedStatusFilter = nil
        isLoading = true
        error = nil

        await loadProjects(for: owner, generation: generation)
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        guard let selectedId = selectedProjectId else {
            await loadProjects()
            return
        }

        await loadProjectDetails(id: selectedId)
    }

    func startPolling() {
        stopPolling()

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 45))

                if Task.isCancelled { break }

                await self?.refresh()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func detectStatusChanges(oldItems: [ProjectItem], newItems: [ProjectItem]) async {
        let oldStatusMap = Dictionary(uniqueKeysWithValues: oldItems.map { ($0.id, $0.status) })

        for newItem in newItems {
            guard let oldStatus = oldStatusMap[newItem.id] else {
                continue
            }

            if oldStatus != newItem.status {
                let fromStatus = oldStatus ?? "No Status"
                let toStatus = newItem.status ?? "No Status"

                await notificationService.sendStatusChangeNotification(
                    itemTitle: newItem.title,
                    fromStatus: fromStatus,
                    toStatus: toStatus
                )
            }
        }
    }

    func selectProject(_ project: Project) async {
        guard project.id != selectedProjectId || project.items.isEmpty else { return }
        selectedProjectId = project.id
        selectedStatusFilter = nil
        error = nil
        await loadProjectDetails(id: project.id)
    }

    func openProject(_ reference: FollowedProject) async {
        if selectedOwnerId != reference.owner.id {
            let owner = owners.first { $0.id == reference.owner.id } ?? reference.owner
            await selectOwner(owner)
        }
        if let project = projects.first(where: { $0.id == reference.id }) {
            await selectProject(project)
        }
    }

    private func loadProjects(for owner: ProjectOwner, generation: Int) async {
        do {
            let loadedProjects = try await gitHubService.fetchProjects(owner: owner)
            guard generation == catalogGeneration, selectedOwnerId == owner.id else { return }
            let cachedProjects = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
            projects = loadedProjects.map { project in
                guard isShowingCachedData, let cached = cachedProjects[project.id] else {
                    return project
                }
                return Project(
                    id: project.id,
                    owner: project.owner,
                    title: project.title,
                    number: project.number,
                    url: project.url,
                    viewerCanUpdate: false,
                    fields: cached.fields,
                    statusField: cached.statusField,
                    items: cached.items
                )
            }

            let selectedProject = loadedProjects.first { $0.id == selectedProjectId }
                ?? loadedProjects.first
            selectedProjectId = selectedProject?.id

            if let selectedProject {
                await loadProjectDetails(id: selectedProject.id)
            }

            guard generation == catalogGeneration else { return }
            lastUpdated = Date()
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard generation == catalogGeneration else { return }
            if isShowingCachedData {
                self.error = nil
                operationErrorMessage = "Showing cached data because the project list could not refresh: \(error.localizedDescription)"
            } else {
                projects = []
                selectedProjectId = nil
                self.error = error
            }
            isLoading = false
        }
    }

    private func restoreCacheIfNeeded() async {
        guard didRestoreCache == false else { return }
        didRestoreCache = true

        guard let snapshot = try? await projectCache.load(),
              snapshot.projects.isEmpty == false else { return }

        cachedAccountLogin = snapshot.accountLogin
        currentUserLogin = snapshot.accountLogin
        owners = [snapshot.owner]
        projects = snapshot.projects.map(makeReadOnly)
        selectedOwnerId = snapshot.owner.id
        selectedProjectId = snapshot.projects.contains { $0.id == snapshot.selectedProjectId }
            ? snapshot.selectedProjectId
            : snapshot.projects.first?.id

        if let selectedStatusFilter = snapshot.selectedStatusFilter,
           selectedProject?.statusOptions.contains(where: { $0.name == selectedStatusFilter }) == true {
            self.selectedStatusFilter = selectedStatusFilter
        } else {
            self.selectedStatusFilter = nil
        }
        lastUpdated = snapshot.savedAt
        isShowingCachedData = true
    }

    private func persistCache() async {
        guard let accountLogin = currentUserLogin,
              let owner = selectedOwner,
              projects.isEmpty == false else { return }
        do {
            try await projectCache.save(
                ProjectCacheSnapshot(
                    accountLogin: accountLogin,
                    owner: owner,
                    projects: projects,
                    selectedProjectId: selectedProjectId,
                    selectedStatusFilter: selectedStatusFilter
                )
            )
            cachedAccountLogin = accountLogin
        } catch {
            operationErrorMessage = "Project loaded, but the local cache could not be updated: \(error.localizedDescription)"
        }
    }

    private func makeReadOnly(_ project: Project) -> Project {
        Project(
            id: project.id,
            owner: project.owner,
            title: project.title,
            number: project.number,
            url: project.url,
            viewerCanUpdate: false,
            fields: project.fields,
            statusField: project.statusField,
            items: project.items
        )
    }

    private func cachedDataMessage(for state: GitHubSessionState) -> String {
        let reason = sessionError(for: state)?.localizedDescription ?? "GitHub is unavailable."
        return "Showing cached data. \(reason)"
    }

    private func sessionError(for state: GitHubSessionState) -> GitHubError? {
        switch state {
        case .checking, .ready:
            return nil
        case .missingCLI:
            return .ghCLINotFound
        case .signedOut:
            return .notAuthenticated
        case .missingProjectScope:
            return .missingProjectScope
        case .failed(let message):
            return .processError(message)
        }
    }

    func moveItem(_ item: ProjectItem, toStatus status: StatusOption) async {
        guard let project = selectedProject, project.viewerCanUpdate,
              let fieldId = project.statusField?.id,
              let projectIndex = projects.firstIndex(where: { $0.id == project.id }),
              let itemIndex = projects[projectIndex].items.firstIndex(where: { $0.id == item.id }) else { return }

        // Store original for potential revert
        let originalProject = projects[projectIndex]

        // Optimistic update - create new item with updated status
        let updatedItem = ProjectItem(
            id: item.id,
            contentId: item.contentId,
            contentType: item.contentType,
            title: item.title,
            number: item.number,
            url: item.url,
            issueState: item.issueState,
            prState: item.prState,
            updatedAt: item.updatedAt,
            status: status.name,
            statusOptionId: status.id,
            assignees: item.assignees,
            labels: item.labels,
            fieldValues: item.fieldValues.merging([
                fieldId: .singleSelect(optionId: status.id, name: status.name)
            ]) { _, new in new },
            linkedPR: item.linkedPR
        )

        // Create new items array and replace the entire project to trigger @Observable update
        var newItems = projects[projectIndex].items
        newItems[itemIndex] = updatedItem
        projects[projectIndex] = Project(
            id: project.id,
            owner: project.owner,
            title: project.title,
            number: project.number,
            url: project.url,
            viewerCanUpdate: project.viewerCanUpdate,
            fields: project.fields,
            statusField: project.statusField,
            items: newItems
        )

        // Then sync with server
        do {
            try await gitHubService.updateItemStatus(
                projectId: project.id,
                itemId: item.id,
                fieldId: fieldId,
                optionId: status.id
            )
            lastUpdated = Date()
            await persistCache()
        } catch {
            // Revert on error - restore original project
            projects[projectIndex] = originalProject
            operationErrorMessage = error.localizedDescription
        }
    }

    func deleteItem(_ item: ProjectItem) async {
        guard let project = selectedProject, project.viewerCanUpdate else { return }

        do {
            try await gitHubService.deleteItem(projectId: project.id, itemId: item.id)
            await refresh()
        } catch {
            operationErrorMessage = error.localizedDescription
        }
    }

    func archiveItem(_ item: ProjectItem) async -> Bool {
        guard let project = editableSelectedProject() else { return false }
        operationErrorMessage = nil

        do {
            try await gitHubService.archiveItem(projectId: project.id, itemId: item.id)
            if let projectIndex = projects.firstIndex(where: { $0.id == project.id }) {
                projects[projectIndex].items.removeAll { $0.id == item.id }
            }
            lastUpdated = Date()
            await persistCache()
            return true
        } catch is CancellationError {
            return false
        } catch {
            operationErrorMessage = error.localizedDescription
            return false
        }
    }

    func updateField(
        on item: ProjectItem,
        field: ProjectField,
        value: ProjectFieldValue?
    ) async -> Bool {
        guard let project = editableSelectedProject() else { return false }
        operationErrorMessage = nil

        do {
            try await gitHubService.updateItemField(
                projectId: project.id,
                itemId: item.id,
                fieldId: field.id,
                value: value
            )
            await loadProjectDetails(id: project.id)
            return true
        } catch is CancellationError {
            return false
        } catch {
            operationErrorMessage = error.localizedDescription
            return false
        }
    }

    func moveItems(_ items: [ProjectItem], to status: StatusOption) async {
        for item in items where item.status != status.name {
            await moveItem(item, toStatus: status)
        }
    }

    func archiveItems(_ items: [ProjectItem]) async {
        for item in items {
            _ = await archiveItem(item)
        }
    }

    func searchUsers(query: String) async -> [Assignee] {
        operationErrorMessage = nil
        do {
            return try await gitHubService.searchUsers(query: query)
        } catch {
            operationErrorMessage = error.localizedDescription
            return []
        }
    }

    func addAssignee(to item: ProjectItem, user: Assignee) async {
        guard let url = item.url,
              let project = selectedProject, project.viewerCanUpdate,
              let projectIndex = projects.firstIndex(where: { $0.id == project.id }),
              let itemIndex = projects[projectIndex].items.firstIndex(where: { $0.id == item.id }) else { return }

        // Store original for potential revert
        let originalProject = projects[projectIndex]

        // Optimistic update - add assignee to local state
        var newAssignees = item.assignees
        if !newAssignees.contains(where: { $0.login == user.login }) {
            newAssignees.append(user)
        }

        let updatedItem = ProjectItem(
            id: item.id,
            contentId: item.contentId,
            contentType: item.contentType,
            title: item.title,
            number: item.number,
            url: item.url,
            issueState: item.issueState,
            prState: item.prState,
            updatedAt: item.updatedAt,
            status: item.status,
            statusOptionId: item.statusOptionId,
            assignees: newAssignees,
            labels: item.labels,
            fieldValues: item.fieldValues,
            linkedPR: item.linkedPR
        )

        var newItems = projects[projectIndex].items
        newItems[itemIndex] = updatedItem
        projects[projectIndex] = Project(
            id: project.id,
            owner: project.owner,
            title: project.title,
            number: project.number,
            url: project.url,
            viewerCanUpdate: project.viewerCanUpdate,
            fields: project.fields,
            statusField: project.statusField,
            items: newItems
        )

        do {
            try await gitHubService.addAssignee(issueUrl: url, userLogin: user.login)
            lastUpdated = Date()
            await persistCache()
        } catch {
            // Revert on error
            projects[projectIndex] = originalProject
            operationErrorMessage = error.localizedDescription
        }
    }

    func removeAssignee(from item: ProjectItem, user: Assignee) async {
        guard let url = item.url,
              let project = selectedProject, project.viewerCanUpdate,
              let projectIndex = projects.firstIndex(where: { $0.id == project.id }),
              let itemIndex = projects[projectIndex].items.firstIndex(where: { $0.id == item.id }) else { return }

        // Store original for potential revert
        let originalProject = projects[projectIndex]

        // Optimistic update - remove assignee from local state
        let newAssignees = item.assignees.filter { $0.login != user.login }

        let updatedItem = ProjectItem(
            id: item.id,
            contentId: item.contentId,
            contentType: item.contentType,
            title: item.title,
            number: item.number,
            url: item.url,
            issueState: item.issueState,
            prState: item.prState,
            updatedAt: item.updatedAt,
            status: item.status,
            statusOptionId: item.statusOptionId,
            assignees: newAssignees,
            labels: item.labels,
            fieldValues: item.fieldValues,
            linkedPR: item.linkedPR
        )

        var newItems = projects[projectIndex].items
        newItems[itemIndex] = updatedItem
        projects[projectIndex] = Project(
            id: project.id,
            owner: project.owner,
            title: project.title,
            number: project.number,
            url: project.url,
            viewerCanUpdate: project.viewerCanUpdate,
            fields: project.fields,
            statusField: project.statusField,
            items: newItems
        )

        do {
            try await gitHubService.removeAssignee(issueUrl: url, userLogin: user.login)
            lastUpdated = Date()
            await persistCache()
        } catch {
            // Revert on error
            projects[projectIndex] = originalProject
            operationErrorMessage = error.localizedDescription
        }
    }

    func addLabel(to item: ProjectItem, name: String) async -> Bool {
        guard let url = item.url, editableSelectedProject() != nil else { return false }
        operationErrorMessage = nil

        do {
            try await gitHubService.addLabel(issueUrl: url, label: name)
            if let projectId = selectedProjectId {
                await loadProjectDetails(id: projectId)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            operationErrorMessage = error.localizedDescription
            return false
        }
    }

    func removeLabel(from item: ProjectItem, name: String) async -> Bool {
        guard let url = item.url, editableSelectedProject() != nil else { return false }
        operationErrorMessage = nil

        do {
            try await gitHubService.removeLabel(issueUrl: url, label: name)
            if let projectId = selectedProjectId {
                await loadProjectDetails(id: projectId)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            operationErrorMessage = error.localizedDescription
            return false
        }
    }

    func createIssueAndAdd(
        repository: String,
        title: String,
        labels: [String],
        assignees: [String]
    ) async -> Bool {
        guard let project = editableSelectedProject() else { return false }
        operationErrorMessage = nil

        do {
            try await gitHubService.createIssueAndAdd(
                projectId: project.id,
                repository: repository,
                title: title,
                labels: labels,
                assignees: assignees
            )
            await refresh()
            return true
        } catch is CancellationError {
            return false
        } catch {
            operationErrorMessage = error.localizedDescription
            return false
        }
    }

    func createDraftIssue(title: String) async -> Bool {
        guard let project = editableSelectedProject() else { return false }
        operationErrorMessage = nil

        do {
            _ = try await gitHubService.createDraftIssue(projectId: project.id, title: title)
            await refresh()
            return true
        } catch is CancellationError {
            return false
        } catch {
            operationErrorMessage = error.localizedDescription
            return false
        }
    }

    func searchItems(query: String) async -> [GitHubItemCandidate] {
        operationErrorMessage = nil
        do {
            return try await gitHubService.searchItems(query: query)
        } catch is CancellationError {
            return []
        } catch {
            operationErrorMessage = error.localizedDescription
            return []
        }
    }

    func addExistingItem(url: String) async -> Bool {
        guard let project = editableSelectedProject() else { return false }
        operationErrorMessage = nil

        do {
            try await gitHubService.addExistingItem(projectId: project.id, url: url)
            await refresh()
            return true
        } catch is CancellationError {
            return false
        } catch {
            operationErrorMessage = error.localizedDescription
            return false
        }
    }

    func addExistingItem(_ candidate: GitHubItemCandidate) async -> Bool {
        guard let project = editableSelectedProject() else { return false }
        operationErrorMessage = nil

        do {
            try await gitHubService.addExistingItem(projectId: project.id, candidate: candidate)
            await refresh()
            return true
        } catch is CancellationError {
            return false
        } catch {
            operationErrorMessage = error.localizedDescription
            return false
        }
    }

    func clearOperationError() {
        operationErrorMessage = nil
    }

    private func editableSelectedProject() -> Project? {
        guard let project = selectedProject, project.viewerCanUpdate else {
            operationErrorMessage = "This project is read-only."
            return nil
        }
        return project
    }
}
