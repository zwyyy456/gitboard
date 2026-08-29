import Foundation
import SwiftUI

enum ProjectContentPhase: Equatable {
    case summary
    case cached
    case loading
    case loaded
    case refreshing
    case failed(String)
}

enum SelectedProjectContentState: Equatable {
    case none
    case loading(Project)
    case content(Project, isRefreshing: Bool, isCached: Bool)
    case empty(Project, isRefreshing: Bool, isCached: Bool)
    case failed(Project, String)
}

private struct ItemDetailEntry {
    let sourceUpdatedAt: String?
    let state: ItemDetailState
}

@MainActor
@Observable
final class ProjectStore {
    var sessionState: GitHubSessionState = .checking
    var owners: [ProjectOwner] = []
    var projects: [Project] = []
    var selectedOwnerId: String? {
        didSet {
            defaults.set(selectedOwnerId, forKey: "selectedOwnerId")
        }
    }
    var selectedProjectId: String? {
        didSet {
            defaults.set(selectedProjectId, forKey: "selectedProjectId")
        }
    }

    // nil means "All", otherwise filter by status name
    var selectedStatusFilter: String? {
        didSet {
            defaults.set(selectedStatusFilter, forKey: "selectedStatusFilter")
        }
    }

    var isLoading = false
    var error: Error?
    var operationErrorMessage: String?
    var lastUpdated: Date?
    var currentUserLogin: String?

    private var catalogGeneration = 0
    private var projectGeneration = 0
    private var didRestoreCache = false
    private var cachedAccountLogin: String?
    private var projectContentPhases: [String: ProjectContentPhase] = [:]
    private var detailedProjectIDs: Set<String> = []
    private var cachedProjectIDs: Set<String> = []
    private var loadingProjectID: String?
    private var projectLoadTask: Task<Project, Error>?
    private var itemDetailEntries: [String: ItemDetailEntry] = [:]
    private var itemDetailTasks: [String: Task<ProjectItemDetail, Error>] = [:]
    private var itemDetailGenerations: [String: Int] = [:]

    private let gitHubService: GitHubService
    private let projectCache: ProjectCache
    private let defaults: UserDefaults

    var selectedProject: Project? {
        guard let id = selectedProjectId else { return nil }
        return projects.first { $0.id == id }
    }

    var selectedOwner: ProjectOwner? {
        guard let id = selectedOwnerId else { return nil }
        return owners.first { $0.id == id }
    }

    var selectedProjectContentState: SelectedProjectContentState {
        guard let project = selectedProject else { return .none }

        switch projectContentPhases[project.id] ?? .summary {
        case .summary, .loading:
            return .loading(project)
        case .cached:
            return project.items.isEmpty
                ? .empty(project, isRefreshing: false, isCached: true)
                : .content(project, isRefreshing: false, isCached: true)
        case .loaded:
            return project.items.isEmpty
                ? .empty(project, isRefreshing: false, isCached: false)
                : .content(project, isRefreshing: false, isCached: false)
        case .refreshing:
            let isCached = cachedProjectIDs.contains(project.id)
            return project.items.isEmpty
                ? .empty(project, isRefreshing: true, isCached: isCached)
                : .content(project, isRefreshing: true, isCached: isCached)
        case .failed(let message):
            return .failed(project, message)
        }
    }

    var isShowingCachedData: Bool {
        selectedProjectId.map(cachedProjectIDs.contains) ?? false
    }

    var canEditSelectedProject: Bool {
        selectedProjectId.map(canEditProject) ?? false
    }

    func project(id: String) -> Project? {
        projects.first { $0.id == id }
    }

    func item(for reference: ItemInspectorReference) -> ProjectItem? {
        project(id: reference.projectID)?.items.first { $0.id == reference.itemID }
    }

    func canEditProject(id: String) -> Bool {
        guard let project = project(id: id), project.viewerCanUpdate else { return false }
        return projectContentPhases[id] == .loaded
    }

    func itemDetailState(for item: ProjectItem) -> ItemDetailState {
        guard let contentID = item.contentId else {
            return .failed("Details are unavailable for this item.")
        }
        guard let entry = itemDetailEntries[contentID],
              entry.sourceUpdatedAt == item.updatedAt else { return .idle }
        return entry.state
    }

    func loadItemDetail(for item: ProjectItem, forceRefresh: Bool = false) async {
        guard let contentID = item.contentId else { return }

        if forceRefresh == false,
           let entry = itemDetailEntries[contentID],
           entry.sourceUpdatedAt == item.updatedAt {
            switch entry.state {
            case .loaded:
                return
            case .loading:
                if let task = itemDetailTasks[contentID] {
                    await finishItemDetailLoad(
                        task,
                        contentID: contentID,
                        sourceUpdatedAt: item.updatedAt,
                        generation: itemDetailGenerations[contentID, default: 0]
                    )
                }
                return
            case .idle, .failed:
                break
            }
        }

        itemDetailTasks[contentID]?.cancel()
        let generation = itemDetailGenerations[contentID, default: 0] + 1
        itemDetailGenerations[contentID] = generation
        itemDetailEntries[contentID] = ItemDetailEntry(
            sourceUpdatedAt: item.updatedAt,
            state: .loading
        )

        let task = Task { try await gitHubService.fetchItemDetail(contentID: contentID) }
        itemDetailTasks[contentID] = task
        await finishItemDetailLoad(
            task,
            contentID: contentID,
            sourceUpdatedAt: item.updatedAt,
            generation: generation
        )
    }

    var filteredItems: [ProjectItem] {
        guard let project = selectedProject else { return [] }
        guard let filter = selectedStatusFilter else { return project.items }
        return project.items.filter { $0.status == filter }
    }

    var repositorySuggestions: [String] {
        guard let project = selectedProject else { return [] }
        return Array(Set(project.items.compactMap(\.repositoryName))).sorted()
    }

    init(
        gitHubService: GitHubService = .shared,
        projectCache: ProjectCache = ProjectCache(),
        defaults: UserDefaults = .standard
    ) {
        self.gitHubService = gitHubService
        self.projectCache = projectCache
        self.defaults = defaults
        selectedOwnerId = defaults.string(forKey: "selectedOwnerId")
        selectedProjectId = defaults.string(forKey: "selectedProjectId")
        selectedStatusFilter = defaults.string(forKey: "selectedStatusFilter")
    }

    func loadProjects() async {
        cancelProjectLoad()
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
            projectContentPhases = [:]
            detailedProjectIDs = []
            cachedProjectIDs = []
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
            if isShowingCachedData {
                self.error = nil
                operationErrorMessage = "Showing cached data because GitHub owners could not refresh: \(error.localizedDescription)"
            } else {
                self.error = error
            }
            isLoading = false
        }
    }

    func loadProjectDetails(id: String) async {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        cancelProjectLoad()
        let generation = projectGeneration
        let hadDetails = detailedProjectIDs.contains(id)
        let fallbackPhase: ProjectContentPhase = if cachedProjectIDs.contains(id) {
            .cached
        } else if hadDetails {
            .loaded
        } else {
            .summary
        }

        projectContentPhases[id] = hadDetails ? .refreshing : .loading
        loadingProjectID = id
        operationErrorMessage = nil
        let task = Task { try await gitHubService.fetchProjectWithItems(project: project) }
        projectLoadTask = task

        do {
            let detailedProject = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard generation == projectGeneration, selectedProjectId == id else { return }

            if let index = projects.firstIndex(where: { $0.id == id }) {
                projects[index] = detailedProject
            }

            projectLoadTask = nil
            loadingProjectID = nil
            detailedProjectIDs.insert(id)
            cachedProjectIDs.remove(id)
            projectContentPhases[id] = .loaded
            lastUpdated = Date()
            operationErrorMessage = nil
            await persistCache()
        } catch is CancellationError {
            guard generation == projectGeneration else { return }
            projectLoadTask = nil
            loadingProjectID = nil
            projectContentPhases[id] = fallbackPhase
            return
        } catch {
            guard generation == projectGeneration, selectedProjectId == id else { return }
            projectLoadTask = nil
            loadingProjectID = nil
            if hadDetails {
                projectContentPhases[id] = fallbackPhase
                let prefix = cachedProjectIDs.contains(id) ? "Showing cached data" : "Keeping the current project"
                operationErrorMessage = "\(prefix) because GitHub refresh failed: \(error.localizedDescription)"
            } else {
                projectContentPhases[id] = .failed(error.localizedDescription)
            }
        }
    }

    func selectOwner(_ owner: ProjectOwner) async {
        guard owner.id != selectedOwnerId else { return }
        cancelProjectLoad()
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
        guard let selectedId = selectedProjectId else {
            await loadProjects()
            return
        }

        await loadProjectDetails(id: selectedId)
    }

    func selectProject(_ project: Project) async {
        let phase = projectContentPhases[project.id] ?? .summary
        guard project.id != selectedProjectId || phase != .loaded else { return }
        selectedProjectId = project.id
        selectedStatusFilter = nil
        operationErrorMessage = nil
        guard phase != .loading, phase != .refreshing else { return }
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
            let detailedProjects = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
            projects = loadedProjects.map { project in
                guard detailedProjectIDs.contains(project.id),
                      let detailed = detailedProjects[project.id] else {
                    return project
                }
                return Project(
                    id: project.id,
                    owner: project.owner,
                    title: project.title,
                    number: project.number,
                    url: project.url,
                    viewerCanUpdate: cachedProjectIDs.contains(project.id)
                        ? false
                        : project.viewerCanUpdate,
                    fields: detailed.fields,
                    statusField: detailed.statusField,
                    items: detailed.items
                )
            }

            let projectIDs = Set(loadedProjects.map(\.id))
            detailedProjectIDs.formIntersection(projectIDs)
            cachedProjectIDs.formIntersection(projectIDs)
            projectContentPhases = projectContentPhases.filter { projectIDs.contains($0.key) }
            for project in projects where projectContentPhases[project.id] == nil {
                projectContentPhases[project.id] = detailedProjectIDs.contains(project.id)
                    ? (cachedProjectIDs.contains(project.id) ? .cached : .loaded)
                    : .summary
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
        let projectIDs = Set(projects.map(\.id))
        detailedProjectIDs = snapshot.detailedProjectIDs.intersection(projectIDs)
        cachedProjectIDs = detailedProjectIDs
        projectContentPhases = Dictionary(uniqueKeysWithValues: projects.map { project in
            (project.id, detailedProjectIDs.contains(project.id) ? .cached : .summary)
        })
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
                    detailedProjectIDs: detailedProjectIDs,
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

    private func cancelProjectLoad() {
        if let loadingProjectID {
            projectContentPhases[loadingProjectID] = cachedProjectIDs.contains(loadingProjectID)
                ? .cached
                : (detailedProjectIDs.contains(loadingProjectID) ? .loaded : .summary)
        }
        projectLoadTask?.cancel()
        projectLoadTask = nil
        loadingProjectID = nil
        projectGeneration += 1
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

    func moveItem(
        _ item: ProjectItem,
        toStatus status: StatusOption,
        in projectID: String
    ) async {
        guard let project = editableProject(id: projectID),
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
            linkedPR: item.linkedPR,
            engineeringSignals: item.engineeringSignals
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

    func deleteItem(_ item: ProjectItem, from projectID: String) async {
        guard let project = editableProject(id: projectID) else { return }

        do {
            try await gitHubService.deleteItem(projectId: project.id, itemId: item.id)
            if let projectIndex = projects.firstIndex(where: { $0.id == project.id }) {
                projects[projectIndex].items.removeAll { $0.id == item.id }
            }
            removeItemDetail(for: item)
            lastUpdated = Date()
            await persistCache()
        } catch {
            operationErrorMessage = error.localizedDescription
        }
    }

    func archiveItem(_ item: ProjectItem, in projectID: String) async -> Bool {
        guard let project = editableProject(id: projectID) else { return false }
        operationErrorMessage = nil

        do {
            try await gitHubService.archiveItem(projectId: project.id, itemId: item.id)
            if let projectIndex = projects.firstIndex(where: { $0.id == project.id }) {
                projects[projectIndex].items.removeAll { $0.id == item.id }
            }
            removeItemDetail(for: item)
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
        in projectID: String,
        field: ProjectField,
        value: ProjectFieldValue?
    ) async -> Bool {
        guard let project = editableProject(id: projectID) else { return false }
        operationErrorMessage = nil

        do {
            try await gitHubService.updateItemField(
                projectId: project.id,
                itemId: item.id,
                fieldId: field.id,
                value: value
            )
            if selectedProjectId == project.id {
                await loadProjectDetails(id: project.id)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            operationErrorMessage = error.localizedDescription
            return false
        }
    }

    func moveItems(
        _ items: [ProjectItem],
        to status: StatusOption,
        in projectID: String
    ) async {
        for item in items where item.status != status.name {
            await moveItem(item, toStatus: status, in: projectID)
        }
    }

    func archiveItems(_ items: [ProjectItem], in projectID: String) async {
        for item in items {
            _ = await archiveItem(item, in: projectID)
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

    func addAssignee(to item: ProjectItem, in projectID: String, user: Assignee) async {
        guard let url = item.url,
              let project = editableProject(id: projectID),
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
            linkedPR: item.linkedPR,
            engineeringSignals: item.engineeringSignals
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

    func removeAssignee(from item: ProjectItem, in projectID: String, user: Assignee) async {
        guard let url = item.url,
              let project = editableProject(id: projectID),
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
            linkedPR: item.linkedPR,
            engineeringSignals: item.engineeringSignals
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

    func addLabel(to item: ProjectItem, in projectID: String, name: String) async -> Bool {
        guard let url = item.url, editableProject(id: projectID) != nil else { return false }
        operationErrorMessage = nil

        do {
            try await gitHubService.addLabel(issueUrl: url, label: name)
            if selectedProjectId == projectID {
                await loadProjectDetails(id: projectID)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            operationErrorMessage = error.localizedDescription
            return false
        }
    }

    func removeLabel(from item: ProjectItem, in projectID: String, name: String) async -> Bool {
        guard let url = item.url, editableProject(id: projectID) != nil else { return false }
        operationErrorMessage = nil

        do {
            try await gitHubService.removeLabel(issueUrl: url, label: name)
            if selectedProjectId == projectID {
                await loadProjectDetails(id: projectID)
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
        assignees: [String],
        status: String? = nil,
        priority: String? = nil
    ) async -> Bool {
        guard let project = editableSelectedProject() else { return false }
        operationErrorMessage = nil

        let requestedFields = [("Status", status), ("Priority", priority)].compactMap { name, value in
            value.map { (name, $0) }
        }
        var resolvedFields: [(ProjectField, ProjectFieldOption)] = []
        for (name, value) in requestedFields {
            guard let field = project.fields.first(where: {
                $0.kind == .singleSelect && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }), let option = field.options.first(where: {
                $0.name.caseInsensitiveCompare(value) == .orderedSame
            }) else {
                operationErrorMessage = "\(name) has no option named \(value)."
                return false
            }
            resolvedFields.append((field, option))
        }

        do {
            let issueURL = try await gitHubService.createIssueAndAdd(
                projectId: project.id,
                repository: repository,
                title: title,
                labels: labels,
                assignees: assignees
            )
            await refresh()
            guard resolvedFields.isEmpty || selectedProject?.items.contains(where: {
                $0.url == issueURL
            }) == true else {
                operationErrorMessage = "The issue was added, but GitBoard could not apply its Project fields."
                return false
            }
            if let item = selectedProject?.items.first(where: { $0.url == issueURL }) {
                for (field, option) in resolvedFields {
                    try await gitHubService.updateItemField(
                        projectId: project.id,
                        itemId: item.id,
                        fieldId: field.id,
                        value: .singleSelect(optionId: option.id, name: option.name)
                    )
                }
                if resolvedFields.isEmpty == false {
                    await refresh()
                }
            }
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
        guard let selectedProjectId else {
            operationErrorMessage = "No project is selected."
            return nil
        }
        return editableProject(id: selectedProjectId)
    }

    private func editableProject(id: String) -> Project? {
        guard let project = project(id: id), canEditProject(id: id) else {
            operationErrorMessage = "This project is read-only."
            return nil
        }
        return project
    }

    private func finishItemDetailLoad(
        _ task: Task<ProjectItemDetail, Error>,
        contentID: String,
        sourceUpdatedAt: String?,
        generation: Int
    ) async {
        do {
            let detail = try await task.value
            guard itemDetailGenerations[contentID] == generation else { return }
            itemDetailTasks[contentID] = nil
            itemDetailEntries[contentID] = ItemDetailEntry(
                sourceUpdatedAt: sourceUpdatedAt,
                state: .loaded(detail)
            )
        } catch is CancellationError {
            guard itemDetailGenerations[contentID] == generation else { return }
            itemDetailTasks[contentID] = nil
            itemDetailEntries[contentID] = nil
        } catch {
            guard itemDetailGenerations[contentID] == generation else { return }
            itemDetailTasks[contentID] = nil
            itemDetailEntries[contentID] = ItemDetailEntry(
                sourceUpdatedAt: sourceUpdatedAt,
                state: .failed(error.localizedDescription)
            )
        }
    }

    private func removeItemDetail(for item: ProjectItem) {
        guard let contentID = item.contentId else { return }
        itemDetailTasks[contentID]?.cancel()
        itemDetailTasks[contentID] = nil
        itemDetailEntries[contentID] = nil
        itemDetailGenerations[contentID, default: 0] += 1
    }
}
