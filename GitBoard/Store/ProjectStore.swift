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

private struct ItemMutationKey: Hashable {
    enum Aspect: Hashable {
        case status
        case assignee(String)
    }

    let projectID: String
    let itemID: String
    let aspect: Aspect
}

@MainActor
@Observable
final class ProjectStore {
    var sessionState: GitHubSessionState = .checking
    var owners: [ProjectOwner] = []
    private(set) var isLoadingFollowedProjects = false
    private(set) var followedProjectsErrorMessage: String?
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
    private(set) var operationErrorMessage: String?
    var lastUpdated: Date?
    var currentUserLogin: String?

    private var catalogGeneration = 0
    private var projectGeneration = 0
    private var followedProjectsGeneration = 0
    private var projectSnapshots: [String: Project] = [:]
    private var catalogProjectIDs: [String] = []
    private var followedProjectIDs: Set<String> = []
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
    private(set) var refreshingItemReferences: Set<ItemInspectorReference> = []
    private var repositoryMilestones: [String: RepositoryMilestonesState] = [:]
    private var pendingItemMutations: Set<ItemMutationKey> = []
    private var hiddenKanbanStatusIDsByProject: [String: Set<String>]

    private let gitHubService: GitHubService
    private let projectCache: ProjectCache
    private let defaults: UserDefaults

    private static let defaultVisibleKanbanStatusNames: Set<String> = [
        "backlog",
        "todo",
        "in progress",
        "in review"
    ]
    private static let hiddenKanbanStatusIDsDefaultsKey = "hiddenKanbanStatusIDsByProject"

    var selectedProject: Project? {
        guard let id = selectedProjectId else { return nil }
        return project(id: id)
    }

    var projects: [Project] {
        catalogProjectIDs.compactMap { projectSnapshots[$0] }
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
        projectSnapshots[id]
    }

    var allProjects: [Project] {
        Array(projectSnapshots.values)
    }

    func followedProject(id: String) -> Project? {
        followedProjectIDs.contains(id) ? projectSnapshots[id] : nil
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

    func isRefreshingItem(_ reference: ItemInspectorReference) -> Bool {
        refreshingItemReferences.contains(reference)
    }

    func refreshItem(_ reference: ItemInspectorReference) async throws {
        guard refreshingItemReferences.contains(reference) == false,
              let project = project(id: reference.projectID) else { return }

        refreshingItemReferences.insert(reference)
        defer { refreshingItemReferences.remove(reference) }

        let refreshedProject = try await gitHubService.fetchProjectWithItems(
            id: project.id,
            owner: project.owner
        )
        try Task.checkCancellation()

        replaceProject(refreshedProject)
        lastUpdated = Date()

        if let refreshedItem = item(for: reference) {
            await loadItemDetail(for: refreshedItem, forceRefresh: true)

            if case .loaded(let detail) = itemDetailState(for: refreshedItem),
               let metadata = detail.issueMetadata,
               metadata.viewerCanSetMilestone {
                await loadMilestones(
                    repository: metadata.repository,
                    forceRefresh: true
                )
            }
        }

        try Task.checkCancellation()
        await persistCache()
    }

    func milestoneState(for repository: String) -> RepositoryMilestonesState {
        repositoryMilestones[repository] ?? .idle
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

    func loadMilestones(repository: String, forceRefresh: Bool = false) async {
        if forceRefresh == false {
            switch milestoneState(for: repository) {
            case .loading, .loaded:
                return
            case .idle, .failed:
                break
            }
        }

        repositoryMilestones[repository] = .loading
        do {
            let milestones = try await gitHubService.fetchRepositoryMilestones(
                repository: repository
            )
            repositoryMilestones[repository] = .loaded(milestones)
        } catch is CancellationError {
            repositoryMilestones[repository] = .idle
        } catch {
            repositoryMilestones[repository] = .failed(error.localizedDescription)
        }
    }

    func setMilestone(_ milestone: RepositoryMilestone?, on item: ProjectItem) async throws {
        guard let contentID = item.contentId,
              case .loaded(let detail) = itemDetailState(for: item),
              detail.issueMetadata?.viewerCanSetMilestone == true else { return }

        try await gitHubService.updateIssueMilestone(
            issueID: contentID,
            milestoneID: milestone?.id
        )
        await loadItemDetail(for: item, forceRefresh: true)
    }

    func addRelation(
        _ kind: IssueRelationKind,
        target: GitHubItemCandidate,
        on item: ProjectItem
    ) async throws {
        guard target.contentType == .issue,
              let issueID = item.contentId,
              case .loaded(let detail) = itemDetailState(for: item),
              detail.issueMetadata?.viewerCanUpdate == true else { return }
        let endpoints = kind.endpoints(issueID: issueID, relatedIssueID: target.id)

        switch kind {
        case .parent, .subIssue:
            try await gitHubService.addSubIssue(
                parentIssueID: endpoints.issueID,
                subIssueID: endpoints.relatedIssueID,
                replacingParent: kind == .parent
            )
        case .blockedBy, .blocking:
            try await gitHubService.addBlockedBy(
                issueID: endpoints.issueID,
                blockingIssueID: endpoints.relatedIssueID
            )
        }
        await loadItemDetail(for: item, forceRefresh: true)
    }

    func removeRelation(
        _ kind: IssueRelationKind,
        relatedIssue: IssueReference,
        from item: ProjectItem
    ) async throws {
        guard let issueID = item.contentId,
              case .loaded(let detail) = itemDetailState(for: item),
              detail.issueMetadata?.viewerCanUpdate == true else { return }
        let endpoints = kind.endpoints(issueID: issueID, relatedIssueID: relatedIssue.id)

        switch kind {
        case .parent, .subIssue:
            try await gitHubService.removeSubIssue(
                parentIssueID: endpoints.issueID,
                subIssueID: endpoints.relatedIssueID
            )
        case .blockedBy, .blocking:
            try await gitHubService.removeBlockedBy(
                issueID: endpoints.issueID,
                blockingIssueID: endpoints.relatedIssueID
            )
        }
        await loadItemDetail(for: item, forceRefresh: true)
    }

    var filteredItems: [ProjectItem] {
        guard let project = selectedProject else { return [] }
        guard let filter = selectedStatusFilter else { return project.items }
        return project.items.filter { $0.status == filter }
    }

    func visibleKanbanStatuses(in project: Project) -> [StatusOption] {
        let visibleIDs = visibleKanbanStatusIDs(in: project)
        return project.statusOptions.filter { visibleIDs.contains($0.id) }
    }

    func visibleKanbanStatusIDs(in project: Project) -> Set<String> {
        let availableIDs = Set(project.statusOptions.map(\.id))
        guard availableIDs.isEmpty == false else { return [] }

        if let storedHiddenIDs = hiddenKanbanStatusIDsByProject[project.id] {
            let visibleIDs = availableIDs.subtracting(storedHiddenIDs)
            if visibleIDs.isEmpty == false {
                return visibleIDs
            }
        }

        let defaultVisibleIDs = Set(project.statusOptions.compactMap { status in
            Self.defaultVisibleKanbanStatusNames.contains(Self.normalizedStatusName(status.name))
                ? status.id
                : nil
        })
        return defaultVisibleIDs.isEmpty ? availableIDs : defaultVisibleIDs
    }

    func setKanbanStatus(
        _ status: StatusOption,
        visible: Bool,
        in project: Project
    ) {
        let availableIDs = Set(project.statusOptions.map(\.id))
        guard availableIDs.contains(status.id) else { return }

        var hiddenIDs = hiddenKanbanStatusIDsByProject[project.id]
            ?? defaultHiddenKanbanStatusIDs(in: project)
        if visible {
            hiddenIDs.remove(status.id)
        } else {
            let visibleIDs = availableIDs.subtracting(hiddenIDs)
            guard visibleIDs.count > 1 else { return }
            hiddenIDs.insert(status.id)
        }

        hiddenKanbanStatusIDsByProject[project.id] = hiddenIDs.intersection(availableIDs)
        saveHiddenKanbanStatusIDs()
    }

    func showAllKanbanStatuses(in project: Project) {
        hiddenKanbanStatusIDsByProject[project.id] = []
        saveHiddenKanbanStatusIDs()
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
        hiddenKanbanStatusIDsByProject = Self.loadHiddenKanbanStatusIDs(from: defaults)
        selectedOwnerId = defaults.string(forKey: "selectedOwnerId")
        selectedProjectId = defaults.string(forKey: "selectedProjectId")
        selectedStatusFilter = defaults.string(forKey: "selectedStatusFilter")
    }

    private func defaultHiddenKanbanStatusIDs(in project: Project) -> Set<String> {
        let visibleIDs = Set(project.statusOptions.compactMap { status in
            Self.defaultVisibleKanbanStatusNames.contains(Self.normalizedStatusName(status.name))
                ? status.id
                : nil
        })
        guard visibleIDs.isEmpty == false else { return [] }
        return Set(project.statusOptions.map(\.id)).subtracting(visibleIDs)
    }

    private func saveHiddenKanbanStatusIDs() {
        let persistedSelections = hiddenKanbanStatusIDsByProject.mapValues {
            Array($0).sorted()
        }
        guard let data = try? JSONEncoder().encode(persistedSelections) else { return }
        defaults.set(data, forKey: Self.hiddenKanbanStatusIDsDefaultsKey)
    }

    private static func loadHiddenKanbanStatusIDs(
        from defaults: UserDefaults
    ) -> [String: Set<String>] {
        guard let data = defaults.data(forKey: hiddenKanbanStatusIDsDefaultsKey),
              let persistedSelections = try? JSONDecoder().decode(
                [String: [String]].self,
                from: data
              ) else { return [:] }
        return persistedSelections.mapValues(Set.init)
    }

    private static func normalizedStatusName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
            projectSnapshots = [:]
            catalogProjectIDs = []
            followedProjectIDs = []
            followedProjectsGeneration += 1
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
                replaceCatalog(with: [])
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
        guard let project = project(id: id) else { return }
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
        let task = Task {
            try await gitHubService.fetchProjectWithItems(id: project.id, owner: project.owner)
        }
        projectLoadTask = task

        do {
            let detailedProject = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard generation == projectGeneration, selectedProjectId == id else { return }

            replaceProject(detailedProject)

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

    func refreshFollowedProjects(_ references: [FollowedProject]) async {
        setFollowedProjects(references)
        let generation = followedProjectsGeneration

        guard references.isEmpty == false else { return }

        isLoadingFollowedProjects = true
        defer {
            if generation == followedProjectsGeneration {
                isLoadingFollowedProjects = false
            }
        }

        do {
            var loaded: [String: Project] = [:]
            for reference in references {
                try Task.checkCancellation()
                loaded[reference.id] = try await gitHubService.fetchProjectWithItems(
                    id: reference.id,
                    owner: reference.owner
                )
            }
            guard generation == followedProjectsGeneration else { return }
            for project in loaded.values {
                replaceProject(project)
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == followedProjectsGeneration else { return }
            followedProjectsErrorMessage = error.localizedDescription
        }
    }

    func setFollowedProjects(_ references: [FollowedProject]) {
        followedProjectsGeneration += 1
        let previousIDs = followedProjectIDs
        followedProjectIDs = Set(references.map(\.id))
        for id in previousIDs.subtracting(followedProjectIDs)
            where catalogProjectIDs.contains(id) == false {
            projectSnapshots[id] = nil
        }
        let retainedProjectIDs = Set(projects.map(\.id)).union(followedProjectIDs)
        detailedProjectIDs.formIntersection(retainedProjectIDs)
        cachedProjectIDs.formIntersection(retainedProjectIDs)
        projectContentPhases = projectContentPhases.filter {
            retainedProjectIDs.contains($0.key)
        }
        followedProjectsErrorMessage = nil
        isLoadingFollowedProjects = false
    }

    func applyMonitoredSnapshots(_ snapshots: [Project]) {
        for project in snapshots where followedProjectIDs.contains(project.id) {
            replaceProject(project)
        }
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
        if let project = project(id: reference.id) {
            await selectProject(project)
        }
    }

    private func loadProjects(for owner: ProjectOwner, generation: Int) async {
        do {
            let loadedProjects = try await gitHubService.fetchProjects(owner: owner)
            guard generation == catalogGeneration, selectedOwnerId == owner.id else { return }
            let detailedProjects = Dictionary(uniqueKeysWithValues: allProjects.map { ($0.id, $0) })
            let mergedProjects = loadedProjects.map { project in
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
            replaceCatalog(with: mergedProjects)

            let projectIDs = Set(loadedProjects.map(\.id))
            let retainedProjectIDs = projectIDs.union(followedProjectIDs)
            detailedProjectIDs.formIntersection(retainedProjectIDs)
            cachedProjectIDs.formIntersection(retainedProjectIDs)
            projectContentPhases = projectContentPhases.filter {
                retainedProjectIDs.contains($0.key)
            }
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
                replaceCatalog(with: [])
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
        let cachedProjects = snapshot.projects.map(makeReadOnly)
        replaceCatalog(with: cachedProjects)
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

    private func refreshProjectSnapshot(id: String) async {
        guard let project = project(id: id) else { return }
        do {
            let detailedProject = try await gitHubService.fetchProjectWithItems(
                id: project.id,
                owner: project.owner
            )
            replaceProject(detailedProject)
            lastUpdated = Date()
            await persistCache()
        } catch is CancellationError {
            return
        } catch {
            operationErrorMessage = error.localizedDescription
        }
    }

    private func replaceProject(_ project: Project) {
        projectSnapshots[project.id] = project
        detailedProjectIDs.insert(project.id)
        cachedProjectIDs.remove(project.id)
        projectContentPhases[project.id] = .loaded
    }

    private func replaceCatalog(with projects: [Project]) {
        let newIDs = Set(projects.map(\.id))
        for id in Set(catalogProjectIDs).subtracting(newIDs)
            where followedProjectIDs.contains(id) == false {
            projectSnapshots[id] = nil
        }
        catalogProjectIDs = projects.map(\.id)
        for project in projects {
            projectSnapshots[project.id] = project
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
    ) async -> Bool {
        guard let project = editableProject(id: projectID),
              let fieldId = project.statusField?.id,
              let currentItem = project.items.first(where: { $0.id == item.id }) else { return false }
        let mutationKey = ItemMutationKey(
            projectID: projectID,
            itemID: item.id,
            aspect: .status
        )
        guard pendingItemMutations.insert(mutationKey).inserted else { return false }
        defer { pendingItemMutations.remove(mutationKey) }

        let originalStatus = currentItem.status
        let originalStatusOptionId = currentItem.statusOptionId
        let originalFieldValue = currentItem.fieldValues[fieldId]
        updateItem(projectID: projectID, itemID: item.id) { item in
            item.status = status.name
            item.statusOptionId = status.id
            item.fieldValues[fieldId] = .singleSelect(optionId: status.id, name: status.name)
        }

        do {
            try await gitHubService.updateItemStatus(
                projectId: project.id,
                itemId: item.id,
                fieldId: fieldId,
                optionId: status.id
            )
            lastUpdated = Date()
            await persistCache()
            return true
        } catch {
            updateItem(projectID: projectID, itemID: item.id) { item in
                item.status = originalStatus
                item.statusOptionId = originalStatusOptionId
                item.fieldValues[fieldId] = originalFieldValue
            }
            operationErrorMessage = error.localizedDescription
            return false
        }
    }

    func deleteItem(_ item: ProjectItem, from projectID: String) async {
        guard let project = editableProject(id: projectID) else { return }

        do {
            try await gitHubService.deleteItem(projectId: project.id, itemId: item.id)
            var updatedProject = project
            updatedProject.items.removeAll { $0.id == item.id }
            replaceProject(updatedProject)
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
            var updatedProject = project
            updatedProject.items.removeAll { $0.id == item.id }
            replaceProject(updatedProject)
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
            } else {
                await refreshProjectSnapshot(id: project.id)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            operationErrorMessage = error.localizedDescription
            return false
        }
    }

    func moveItemToStatus(
        projectID: String,
        itemID: String,
        fieldID: String,
        optionID: String
    ) async -> Bool {
        guard let project = project(id: projectID),
              project.statusField?.id == fieldID,
              let option = project.statusOptions.first(where: { $0.id == optionID }),
              let item = project.items.first(where: { $0.id == itemID }) else { return false }
        return await moveItem(item, toStatus: option, in: projectID)
    }

    func moveItems(
        _ items: [ProjectItem],
        to status: StatusOption,
        in projectID: String
    ) async {
        for item in items where item.status != status.name {
            _ = await moveItem(item, toStatus: status, in: projectID)
        }
    }

    func archiveItems(_ items: [ProjectItem], in projectID: String) async {
        for item in items {
            _ = await archiveItem(item, in: projectID)
        }
    }

    func searchUsers(query: String) async throws -> [Assignee] {
        try await gitHubService.searchUsers(query: query)
    }

    func addAssignee(to item: ProjectItem, in projectID: String, user: Assignee) async throws {
        guard let url = item.url,
              let project = project(id: projectID),
              canEditProject(id: projectID),
              let currentItem = project.items.first(where: { $0.id == item.id }),
              currentItem.assignees.contains(where: { $0.login == user.login }) == false else { return }
        let mutationKey = ItemMutationKey(
            projectID: projectID,
            itemID: item.id,
            aspect: .assignee(user.login.lowercased())
        )
        guard pendingItemMutations.insert(mutationKey).inserted else { return }
        defer { pendingItemMutations.remove(mutationKey) }

        updateItem(projectID: projectID, itemID: item.id) { item in
            item.assignees.append(user)
        }

        do {
            try await gitHubService.addAssignee(issueUrl: url, userLogin: user.login)
            lastUpdated = Date()
            await persistCache()
        } catch {
            updateItem(projectID: projectID, itemID: item.id) { item in
                item.assignees.removeAll { $0.login == user.login }
            }
            throw error
        }
    }

    func removeAssignee(from item: ProjectItem, in projectID: String, user: Assignee) async {
        guard let url = item.url,
              let project = editableProject(id: projectID),
              let currentItem = project.items.first(where: { $0.id == item.id }),
              let originalIndex = currentItem.assignees.firstIndex(where: {
                  $0.login == user.login
              }) else { return }
        let mutationKey = ItemMutationKey(
            projectID: projectID,
            itemID: item.id,
            aspect: .assignee(user.login.lowercased())
        )
        guard pendingItemMutations.insert(mutationKey).inserted else { return }
        defer { pendingItemMutations.remove(mutationKey) }

        updateItem(projectID: projectID, itemID: item.id) { item in
            item.assignees.removeAll { $0.login == user.login }
        }

        do {
            try await gitHubService.removeAssignee(issueUrl: url, userLogin: user.login)
            lastUpdated = Date()
            await persistCache()
        } catch {
            updateItem(projectID: projectID, itemID: item.id) { item in
                guard item.assignees.contains(where: { $0.login == user.login }) == false else {
                    return
                }
                item.assignees.insert(user, at: min(originalIndex, item.assignees.count))
            }
            operationErrorMessage = error.localizedDescription
        }
    }

    func addLabel(to item: ProjectItem, in projectID: String, name: String) async throws {
        guard let url = item.url, canEditProject(id: projectID) else { return }

        try await gitHubService.addLabel(issueUrl: url, label: name)
        if selectedProjectId == projectID {
            await loadProjectDetails(id: projectID)
        } else {
            await refreshProjectSnapshot(id: projectID)
        }
    }

    func removeLabel(from item: ProjectItem, in projectID: String, name: String) async throws {
        guard let url = item.url, canEditProject(id: projectID) else { return }

        try await gitHubService.removeLabel(issueUrl: url, label: name)
        if selectedProjectId == projectID {
            await loadProjectDetails(id: projectID)
        } else {
            await refreshProjectSnapshot(id: projectID)
        }
    }

    func createIssueAndAdd(
        repository: String,
        title: String,
        body: String,
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
                body: body,
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

    func createDraftIssue(title: String, body: String) async -> Bool {
        guard let project = editableSelectedProject() else { return false }
        operationErrorMessage = nil

        do {
            _ = try await gitHubService.createDraftIssue(
                projectId: project.id,
                title: title,
                body: body
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

    func searchItems(query: String) async throws -> [GitHubItemCandidate] {
        try await gitHubService.searchItems(query: query)
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

    private func updateItem(
        projectID: String,
        itemID: String,
        transform: (inout ProjectItem) -> Void
    ) {
        guard var project = project(id: projectID),
              let itemIndex = project.items.firstIndex(where: { $0.id == itemID }) else { return }
        transform(&project.items[itemIndex])
        replaceProject(project)
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
