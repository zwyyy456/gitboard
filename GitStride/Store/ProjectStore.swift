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

    private var pollingTask: Task<Void, Never>?
    private var catalogGeneration = 0
    private var projectGeneration = 0

    private let notificationService = NotificationService.shared
    private let gitHubService = GitHubService.shared

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
            error = sessionError(for: session)
            return
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
        } catch is CancellationError {
            return
        } catch {
            guard generation == projectGeneration, selectedProjectId == id else { return }
            self.error = error
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

    private func loadProjects(for owner: ProjectOwner, generation: Int) async {
        do {
            let loadedProjects = try await gitHubService.fetchProjects(owner: owner)
            guard generation == catalogGeneration, selectedOwnerId == owner.id else { return }
            projects = loadedProjects

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
            projects = []
            selectedProjectId = nil
            self.error = error
            isLoading = false
        }
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
            status: status.name,
            statusOptionId: status.id,
            assignees: item.assignees,
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
        } catch {
            // Revert on error - restore original project
            projects[projectIndex] = originalProject
            self.error = error
        }
    }

    func deleteItem(_ item: ProjectItem) async {
        guard let project = selectedProject, project.viewerCanUpdate else { return }

        do {
            try await gitHubService.deleteItem(projectId: project.id, itemId: item.id)
            await refresh()
        } catch {
            self.error = error
        }
    }

    func searchUsers(query: String) async -> [Assignee] {
        do {
            return try await gitHubService.searchUsers(query: query)
        } catch {
            self.error = error
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
            status: item.status,
            statusOptionId: item.statusOptionId,
            assignees: newAssignees,
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
            statusField: project.statusField,
            items: newItems
        )

        do {
            try await gitHubService.addAssignee(issueUrl: url, userLogin: user.login)
            lastUpdated = Date()
        } catch {
            // Revert on error
            projects[projectIndex] = originalProject
            self.error = error
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
            status: item.status,
            statusOptionId: item.statusOptionId,
            assignees: newAssignees,
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
            statusField: project.statusField,
            items: newItems
        )

        do {
            try await gitHubService.removeAssignee(issueUrl: url, userLogin: user.login)
            lastUpdated = Date()
        } catch {
            // Revert on error
            projects[projectIndex] = originalProject
            self.error = error
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
