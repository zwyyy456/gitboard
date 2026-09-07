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

enum ProjectStoreError: LocalizedError {
    case noProjectSelected
    case readOnlyProject
    case itemUnavailable
    case operationInProgress
    case missingFieldOption(field: String, option: String)
    case createdIssueUnavailable

    var errorDescription: String? {
        switch self {
        case .noProjectSelected:
            "No project is selected."
        case .readOnlyProject:
            "This project is read-only."
        case .operationInProgress:
            "Another change to this item is still in progress."
        case .itemUnavailable:
            "This item is no longer available."
        case .missingFieldOption(let field, let option):
            "\(field) has no option named \(option)."
        case .createdIssueUnavailable:
            "The issue was added, but GitStride could not apply its Project fields."
        }
    }
}

struct PendingCreatedIssue: LocalizedError {
    let projectID: String
    let issueURL: String
    let fields: [(ProjectField, ProjectFieldOption)]

    var errorDescription: String? {
        "The issue was created at \(issueURL), but its Project fields could not be completed. Retry to finish this issue."
    }
}

private struct ItemDetailEntry {
    let sourceUpdatedAt: String?
    let state: ItemDetailState
}

private struct ItemMutationKey: Hashable {
    let projectID: String
    let itemID: String
}

private struct PendingStatusMove {
    let operationID: UUID
    let fieldID: String
    let status: StatusOption
}

private struct ProjectState {
    enum Source { case catalog, cache, remote }
    enum Load { case idle, loading, failed(String) }

    let owner: ProjectOwner
    var snapshot: Project?
    var source: Source = .catalog
    var load: Load = .idle
    var latestReadID: UUID?
    var mutationRevision: UInt64 = 0
    var mutations: Set<UUID> = []
    var needsRefresh = false

    var phase: ProjectContentPhase {
        switch load {
        case .loading: return source == .catalog ? .loading : .refreshing
        case .failed(let message):
            if source == .catalog { return .failed(message) }
        case .idle: break
        }
        switch source {
        case .catalog: return .summary
        case .cache: return .cached
        case .remote: return .loaded
        }
    }
}

private struct ProjectReadTicket {
    let projectID: String
    let requestID: UUID
    let mutationRevision: UInt64
    let contentRevision: UInt64
    let followedGeneration: Int?
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
    private var projectStates: [String: ProjectState] = [:]
    private var contentRevision: UInt64 = 0
    private var reconciliationTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var catalogProjectIDs: [String] = []
    private var followedProjectIDs: Set<String> = []
    private var didRestoreCache = false
    private var cachedAccountLogin: String?
    private var projectLoadTask: Task<Project?, Error>?
    private var itemDetailEntries: [String: ItemDetailEntry] = [:]
    private var itemDetailTasks: [String: Task<ProjectItemDetail, Error>] = [:]
    private var itemDetailGenerations: [String: Int] = [:]
    private(set) var refreshingItemReferences: Set<ItemInspectorReference> = []
    private var repositoryMilestones: [String: RepositoryMilestonesState] = [:]
    private var pendingItemMutations: [ItemMutationKey: UUID] = [:]
    private var pendingStatusMoves: [ItemMutationKey: PendingStatusMove] = [:]
    private var pendingContentMutations: [String: UUID] = [:]
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
        catalogProjectIDs.compactMap { project(id: $0) }
    }

    var selectedOwner: ProjectOwner? {
        guard let id = selectedOwnerId else { return nil }
        return owners.first { $0.id == id }
    }

    var selectedProjectContentState: SelectedProjectContentState {
        guard let project = selectedProject else { return .none }

        switch projectStates[project.id]?.phase ?? .summary {
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
            let isCached = projectStates[project.id]?.source == .cache
            return project.items.isEmpty
                ? .empty(project, isRefreshing: true, isCached: isCached)
                : .content(project, isRefreshing: true, isCached: isCached)
        case .failed(let message):
            return .failed(project, message)
        }
    }

    var isShowingCachedData: Bool {
        selectedProjectId.flatMap { projectStates[$0]?.source } == .cache
    }

    var canEditSelectedProject: Bool {
        selectedProjectId.map(canEditProject) ?? false
    }

    func project(id: String) -> Project? {
        guard var project = projectStates[id]?.snapshot else { return nil }
        for (key, move) in pendingStatusMoves where key.projectID == id {
            guard let index = project.items.firstIndex(where: { $0.id == key.itemID }) else { continue }
            project.items[index].status = move.status.name
            project.items[index].statusOptionId = move.status.id
            project.items[index].fieldValues[move.fieldID] = .singleSelect(
                optionId: move.status.id, name: move.status.name
            )
        }
        return project
    }

    var allProjects: [Project] {
        projectStates.keys.compactMap { project(id: $0) }
    }

    func followedProject(id: String) -> Project? {
        followedProjectIDs.contains(id) ? project(id: id) : nil
    }

    func item(for reference: ItemInspectorReference) -> ProjectItem? {
        project(id: reference.projectID)?.items.first { $0.id == reference.itemID }
    }

    func canEditProject(id: String) -> Bool {
        guard let project = project(id: id), project.viewerCanUpdate else { return false }
        return projectStates[id]?.source == .remote
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

        guard try await refreshProjectSnapshot(id: project.id) != nil else { return }

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

        try await performContentMutation([contentID]) {
            try await self.gitHubService.updateIssueMilestone(issueID: contentID, milestoneID: milestone?.id)
        }
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

        var affectedContentIDs: Set<String> = [issueID, target.id]
        if kind == .parent, let previousParent = detail.issueMetadata?.parent {
            affectedContentIDs.insert(previousParent.id)
        }
        try await performContentMutation(affectedContentIDs) {
            switch kind {
            case .parent, .subIssue:
                try await self.gitHubService.addSubIssue(
                    parentIssueID: endpoints.issueID,
                    subIssueID: endpoints.relatedIssueID,
                    replacingParent: kind == .parent
                )
            case .blockedBy, .blocking:
                try await self.gitHubService.addBlockedBy(
                    issueID: endpoints.issueID,
                    blockingIssueID: endpoints.relatedIssueID
                )
            }
        }
        try await refreshContentProjects(affectedContentIDs)
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

        try await performContentMutation([issueID, relatedIssue.id]) {
            switch kind {
            case .parent, .subIssue:
                try await self.gitHubService.removeSubIssue(
                    parentIssueID: endpoints.issueID,
                    subIssueID: endpoints.relatedIssueID
                )
            case .blockedBy, .blocking:
                try await self.gitHubService.removeBlockedBy(
                    issueID: endpoints.issueID,
                    blockingIssueID: endpoints.relatedIssueID
                )
            }
        }
        try await refreshContentProjects([issueID, relatedIssue.id])
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
            projectStates = [:]
            reconciliationTasks.values.forEach { $0.task.cancel() }
            reconciliationTasks = [:]
            pendingStatusMoves = [:]
            pendingItemMutations = [:]
            pendingContentMutations = [:]
            invalidateContentDetails(Array(itemDetailEntries.keys))
            contentRevision += 1
            catalogProjectIDs = []
            followedProjectIDs = []
            followedProjectsGeneration += 1
            selectedOwnerId = nil
            selectedProjectId = nil
            selectedStatusFilter = nil
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
        guard projectStates[id] != nil else { return }
        cancelProjectLoad()
        if let reconciliation = reconciliationTasks[id] {
            await reconciliation.task.value
            return
        }
        let generation = projectGeneration
        operationErrorMessage = nil
        let task = Task { try await refreshProjectSnapshot(id: id) }
        projectLoadTask = task
        defer {
            if generation == projectGeneration {
                projectLoadTask = nil
            }
        }
        do {
            _ = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
        } catch is CancellationError {
        } catch {
            guard generation == projectGeneration else { return }
            operationErrorMessage = error.localizedDescription
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
            _ = try await refreshMonitoredProjects(references)
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
        for reference in references where projectStates[reference.id] == nil {
            projectStates[reference.id] = ProjectState(owner: reference.owner)
        }
        for id in previousIDs.subtracting(followedProjectIDs)
            where !catalogProjectIDs.contains(id) {
            removeProject(id: id)
        }
        followedProjectsErrorMessage = nil
        isLoadingFollowedProjects = false
    }

    // nil means this cycle was superseded, not that the projects are empty.
    func refreshMonitoredProjects(_ references: [FollowedProject]) async throws -> [Project]? {
        let generation = followedProjectsGeneration
        let revision = contentRevision
        let revisions = references.map { projectStates[$0.id]?.mutationRevision }
        var snapshots: [Project] = []
        for reference in references {
            try Task.checkCancellation()
            guard generation == followedProjectsGeneration,
                  followedProjectIDs.contains(reference.id) else { return nil }
            if let snapshot = try await refreshProjectSnapshot(id: reference.id, followedGeneration: generation) {
                snapshots.append(snapshot)
            }
        }
        guard snapshots.count == references.count,
              generation == followedProjectsGeneration, revision == contentRevision,
              revisions == references.map({ projectStates[$0.id]?.mutationRevision }),
              pendingContentMutations.isEmpty,
              references.allSatisfy({ projectStates[$0.id]?.mutations.isEmpty == true }) else { return nil }
        return snapshots
    }

    func selectProject(_ project: Project) async {
        let phase = projectStates[project.id]?.phase ?? .summary
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
            let detailedProjects = projectStates.compactMapValues(\.snapshot)
            let mergedProjects = loadedProjects.map { project in
                guard let source = projectStates[project.id]?.source, source != .catalog,
                      let detailed = detailedProjects[project.id] else {
                    return project
                }
                return Project(
                    id: project.id,
                    owner: project.owner,
                    title: project.title,
                    number: project.number,
                    url: project.url,
                    viewerCanUpdate: projectStates[project.id]?.source == .cache
                        ? false
                        : project.viewerCanUpdate,
                    fields: detailed.fields,
                    statusField: detailed.statusField,
                    items: detailed.items
                )
            }
            replaceCatalog(with: mergedProjects)

            let selectedProject = loadedProjects.first { $0.id == selectedProjectId }
                ?? loadedProjects.first
            selectedProjectId = selectedProject?.id

            if let selectedProject {
                await loadProjectDetails(id: selectedProject.id)
            }

            guard generation == catalogGeneration else { return }
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
        for id in snapshot.detailedProjectIDs where projectStates[id] != nil {
            projectStates[id]?.source = .cache
        }
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
                    projects: catalogProjectIDs.compactMap { projectStates[$0]?.snapshot },
                    detailedProjectIDs: Set(projectStates.compactMap { id, state in
                        state.source == .catalog ? nil : id
                    }),
                    selectedProjectId: selectedProjectId,
                    selectedStatusFilter: selectedStatusFilter
                )
            )
            cachedAccountLogin = accountLogin
        } catch {
            operationErrorMessage = "Project loaded, but the local cache could not be updated: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func refreshProjectSnapshot(id: String, followedGeneration: Int? = nil) async throws -> Project? {
        guard let state = projectStates[id] else { return nil }
        guard state.mutations.isEmpty, pendingContentMutations.isEmpty else {
            projectStates[id]?.needsRefresh = true
            return nil
        }
        let ticket = ProjectReadTicket(
            projectID: id, requestID: UUID(), mutationRevision: state.mutationRevision,
            contentRevision: contentRevision, followedGeneration: followedGeneration
        )
        projectStates[id]?.latestReadID = ticket.requestID
        projectStates[id]?.load = .loading
        projectStates[id]?.needsRefresh = false
        do {
            let snapshot = try await gitHubService.fetchProjectWithItems(id: id, owner: state.owner)
            try Task.checkCancellation()
            guard canCommit(ticket) else {
                discardRead(ticket)
                return nil
            }
            projectStates[id]?.snapshot = snapshot
            projectStates[id]?.source = .remote
            projectStates[id]?.load = .idle
            lastUpdated = Date()
            await persistCache()
            return canCommit(ticket) ? snapshot : nil
        } catch {
            guard canCommit(ticket) else { discardRead(ticket); return nil }
            projectStates[id]?.load = error is CancellationError ? .idle : .failed(error.localizedDescription)
            throw error
        }
    }

    private func canCommit(_ ticket: ProjectReadTicket) -> Bool {
        guard let state = projectStates[ticket.projectID] else { return false }
        return state.latestReadID == ticket.requestID
            && state.mutationRevision == ticket.mutationRevision
            && contentRevision == ticket.contentRevision
            && state.mutations.isEmpty && pendingContentMutations.isEmpty
            && (ticket.followedGeneration == nil || ticket.followedGeneration == followedProjectsGeneration)
    }

    private func discardRead(_ ticket: ProjectReadTicket) {
        guard projectStates[ticket.projectID]?.latestReadID == ticket.requestID else { return }
        projectStates[ticket.projectID]?.load = .idle
        if projectStates[ticket.projectID]?.mutationRevision != ticket.mutationRevision
            || contentRevision != ticket.contentRevision
            || (ticket.followedGeneration != nil && ticket.followedGeneration != followedProjectsGeneration
                && followedProjectIDs.contains(ticket.projectID)) {
            projectStates[ticket.projectID]?.needsRefresh = true
            scheduleReconciliation()
        }
    }

    private func scheduleReconciliation() {
        guard pendingContentMutations.isEmpty else { return }
        for (id, state) in projectStates where state.needsRefresh && state.mutations.isEmpty {
            guard reconciliationTasks[id] == nil else { continue }
            let taskID = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.reconciliationTasks[id]?.id == taskID {
                        self.reconciliationTasks[id] = nil
                        self.scheduleReconciliation()
                    }
                }
                do {
                    try Task.checkCancellation()
                    guard self.projectStates[id]?.needsRefresh == true else { return }
                    _ = try await self.refreshProjectSnapshot(id: id)
                }
                catch is CancellationError {}
                catch { self.operationErrorMessage = error.localizedDescription }
            }
            reconciliationTasks[id] = (taskID, task)
        }
    }

    private func removeProject(id: String) {
        projectStates[id] = nil
        pendingStatusMoves = pendingStatusMoves.filter { $0.key.projectID != id }
        pendingItemMutations = pendingItemMutations.filter { $0.key.projectID != id }
        reconciliationTasks.removeValue(forKey: id)?.task.cancel()
    }

    private func replaceCatalog(with projects: [Project]) {
        let newIDs = Set(projects.map(\.id))
        for id in Set(catalogProjectIDs).subtracting(newIDs) where !followedProjectIDs.contains(id) {
            removeProject(id: id)
        }
        catalogProjectIDs = projects.map(\.id)
        for project in projects {
            if projectStates[project.id] == nil { projectStates[project.id] = ProjectState(owner: project.owner) }
            projectStates[project.id]?.snapshot = project
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
        projectLoadTask?.cancel()
        projectLoadTask = nil
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
        _ item: ProjectItem, toStatus status: StatusOption, in projectID: String
    ) async throws {
        let project = try editableProject(id: projectID)
        guard let fieldID = project.statusField?.id,
              project.items.contains(where: { $0.id == item.id }) else {
            throw ProjectStoreError.itemUnavailable
        }
        try await performProjectMutation(
            projectID: projectID, itemID: item.id, optimisticStatus: (fieldID, status)
        ) {
            try await self.gitHubService.updateItemStatus(
                projectId: projectID, itemId: item.id, fieldId: fieldID, optionId: status.id
            )
        } apply: { _ in
            self.updateItem(projectID: projectID, itemID: item.id) { item in
                item.status = status.name
                item.statusOptionId = status.id
                item.fieldValues[fieldID] = .singleSelect(optionId: status.id, name: status.name)
            }
        }
        await persistCache()
    }

    func deleteItem(_ item: ProjectItem, from projectID: String) async throws {
        _ = try editableProject(id: projectID)
        try await performProjectMutation(projectID: projectID, itemID: item.id) {
            try await self.gitHubService.deleteItem(projectId: projectID, itemId: item.id)
        } apply: { _ in
            self.projectStates[projectID]?.snapshot?.items.removeAll { $0.id == item.id }
            self.invalidateContentDetails([item.contentId].compactMap { $0 })
        }
        await persistCache()
    }

    func archiveItem(_ item: ProjectItem, in projectID: String) async throws {
        _ = try editableProject(id: projectID)
        try await performProjectMutation(projectID: projectID, itemID: item.id) {
            try await self.gitHubService.archiveItem(projectId: projectID, itemId: item.id)
        } apply: { _ in
            self.projectStates[projectID]?.snapshot?.items.removeAll { $0.id == item.id }
            self.invalidateContentDetails([item.contentId].compactMap { $0 })
        }
        await persistCache()
    }

    func updateField(
        on item: ProjectItem, in projectID: String, field: ProjectField, value: ProjectFieldValue?
    ) async throws {
        _ = try editableProject(id: projectID)
        try await performProjectMutation(projectID: projectID, itemID: item.id) {
            try await self.gitHubService.updateItemField(
                projectId: projectID, itemId: item.id, fieldId: field.id, value: value
            )
        } apply: { _ in
            self.updateItem(projectID: projectID, itemID: item.id) { item in
                item.fieldValues[field.id] = value
                if self.projectStates[projectID]?.snapshot?.statusField?.id == field.id {
                    if case .singleSelect(let id, let name) = value {
                        item.status = name
                        item.statusOptionId = id
                    } else {
                        item.status = nil
                        item.statusOptionId = nil
                    }
                }
            }
        }
        await persistCache()
    }

    func moveItemToStatus(
        projectID: String,
        itemID: String,
        fieldID: String,
        optionID: String
    ) async throws {
        guard let project = project(id: projectID),
              project.statusField?.id == fieldID,
              let option = project.statusOptions.first(where: { $0.id == optionID }),
              let item = project.items.first(where: { $0.id == itemID }) else {
            throw ProjectStoreError.itemUnavailable
        }
        try await moveItem(item, toStatus: option, in: projectID)
    }

    func moveItems(
        _ items: [ProjectItem],
        to status: StatusOption,
        in projectID: String
    ) async throws {
        for item in items where item.status != status.name {
            try await moveItem(item, toStatus: status, in: projectID)
        }
    }

    func archiveItems(_ items: [ProjectItem], in projectID: String) async throws {
        for item in items {
            try await archiveItem(item, in: projectID)
        }
    }

    func searchUsers(query: String) async throws -> [Assignee] {
        try await gitHubService.searchUsers(query: query)
    }

    func addAssignee(to item: ProjectItem, in projectID: String, user: Assignee) async throws {
        try await setAssignee(user, assigned: true, on: item, in: projectID)
    }

    func removeAssignee(from item: ProjectItem, in projectID: String, user: Assignee) async throws {
        try await setAssignee(user, assigned: false, on: item, in: projectID)
    }

    private func setAssignee(
        _ user: Assignee, assigned: Bool, on item: ProjectItem, in projectID: String
    ) async throws {
        guard let contentID = item.contentId, let url = item.url,
              canEditProject(id: projectID) else { return }
        try await performContentMutation([contentID]) {
            if assigned {
                try await self.gitHubService.addAssignee(issueUrl: url, userLogin: user.login)
            } else {
                try await self.gitHubService.removeAssignee(issueUrl: url, userLogin: user.login)
            }
        } apply: {
            self.updateContent(contentID: contentID) { item in
                item.assignees.removeAll { $0.login.caseInsensitiveCompare(user.login) == .orderedSame }
                if assigned { item.assignees.append(user) }
            }
        }
        await persistCache()
    }

    func addLabel(to item: ProjectItem, in projectID: String, name: String) async throws {
        try await setLabel(name, assigned: true, on: item, in: projectID)
    }

    func removeLabel(from item: ProjectItem, in projectID: String, name: String) async throws {
        try await setLabel(name, assigned: false, on: item, in: projectID)
    }

    private func setLabel(
        _ name: String, assigned: Bool, on item: ProjectItem, in projectID: String
    ) async throws {
        guard let contentID = item.contentId, let url = item.url,
              canEditProject(id: projectID) else { return }
        try await performContentMutation([contentID]) {
            if assigned {
                try await self.gitHubService.addLabel(issueUrl: url, label: name)
            } else {
                try await self.gitHubService.removeLabel(issueUrl: url, label: name)
            }
        }
        try await refreshContentProjects([contentID])
    }

    func createIssueAndAdd(
        repository: String,
        title: String,
        body: String,
        labels: [String],
        assignees: [String],
        status: String? = nil,
        priority: String? = nil
    ) async throws {
        let project = try editableSelectedProject()

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
                throw ProjectStoreError.missingFieldOption(field: name, option: value)
            }
            resolvedFields.append((field, option))
        }

        let issueURL = try await performProjectMutation(projectID: project.id) {
            try await self.gitHubService.createIssueAndAdd(
                projectId: project.id,
                repository: repository,
                title: title,
                body: body,
                labels: labels,
                assignees: assignees
            )
        }
        try await finishCreatedIssue(PendingCreatedIssue(
            projectID: project.id, issueURL: issueURL, fields: resolvedFields
        ))
    }

    func finishCreatedIssue(_ pending: PendingCreatedIssue) async throws {
        do {
            try await refreshProjectSnapshot(id: pending.projectID)
            guard let item = project(id: pending.projectID)?.items.first(where: {
                $0.url == pending.issueURL
            }) else { throw ProjectStoreError.createdIssueUnavailable }
            try await performProjectMutation(projectID: pending.projectID, itemID: item.id) {
                for (field, option) in pending.fields {
                    try await self.gitHubService.updateItemField(
                        projectId: pending.projectID, itemId: item.id, fieldId: field.id,
                        value: .singleSelect(optionId: option.id, name: option.name)
                    )
                }
            }
            if !pending.fields.isEmpty {
                try await refreshProjectSnapshot(id: pending.projectID)
            }
        } catch {
            // Retain the created identity even after cancellation: submitting
            // the form again must never create a second issue.
            throw pending
        }
    }

    func createDraftIssue(title: String, body: String) async throws {
        let project = try editableSelectedProject()
        _ = try await performProjectMutation(projectID: project.id) {
            try await self.gitHubService.createDraftIssue(projectId: project.id, title: title, body: body)
        }
        try await refreshProjectSnapshot(id: project.id)
    }

    func searchItems(query: String) async throws -> [GitHubItemCandidate] {
        try await gitHubService.searchItems(query: query)
    }

    func addExistingItem(url: String) async throws {
        let project = try editableSelectedProject()
        try await performProjectMutation(projectID: project.id) {
            try await self.gitHubService.addExistingItem(projectId: project.id, url: url)
        }
        try await refreshProjectSnapshot(id: project.id)
    }

    func addExistingItem(_ candidate: GitHubItemCandidate) async throws {
        let project = try editableSelectedProject()
        try await performProjectMutation(projectID: project.id) {
            try await self.gitHubService.addExistingItem(projectId: project.id, candidate: candidate)
        }
        try await refreshProjectSnapshot(id: project.id)
    }

    func clearOperationError() {
        operationErrorMessage = nil
    }

    private func editableSelectedProject() throws -> Project {
        guard let selectedProjectId else { throw ProjectStoreError.noProjectSelected }
        return try editableProject(id: selectedProjectId)
    }

    private func editableProject(id: String) throws -> Project {
        guard let project = project(id: id), canEditProject(id: id) else {
            throw ProjectStoreError.readOnlyProject
        }
        return project
    }

    private func performProjectMutation<Result>(
        projectID: String,
        itemID: String? = nil,
        optimisticStatus: (String, StatusOption)? = nil,
        operation: () async throws -> Result,
        apply: (Result) -> Void = { _ in }
    ) async throws -> Result {
        guard projectStates[projectID] != nil else { throw ProjectStoreError.itemUnavailable }
        let key = itemID.map { ItemMutationKey(projectID: projectID, itemID: $0) }
        if let key, pendingItemMutations[key] != nil { throw ProjectStoreError.operationInProgress }
        let operationID = UUID()
        projectStates[projectID]?.mutations.insert(operationID)
        projectStates[projectID]?.mutationRevision += 1
        if let key {
            pendingItemMutations[key] = operationID
            if let (field, status) = optimisticStatus {
                pendingStatusMoves[key] = PendingStatusMove(operationID: operationID, fieldID: field, status: status)
            }
        }
        defer {
            if let key, pendingItemMutations[key] == operationID {
                pendingItemMutations[key] = nil
                if pendingStatusMoves[key]?.operationID == operationID { pendingStatusMoves[key] = nil }
            }
            if projectStates[projectID]?.mutations.remove(operationID) != nil {
                projectStates[projectID]?.mutationRevision += 1
            }
            scheduleReconciliation()
        }
        do {
            let result = try await operation()
            guard projectStates[projectID]?.mutations.contains(operationID) == true else { throw CancellationError() }
            apply(result)
            lastUpdated = Date()
            return result
        } catch {
            if projectStates[projectID]?.mutations.contains(operationID) == true,
               requiresReconciliation(error) { projectStates[projectID]?.needsRefresh = true }
            throw error
        }
    }

    private func performContentMutation(
        _ contentIDs: Set<String>,
        operation: () async throws -> Void,
        apply: () -> Void = {}
    ) async throws {
        guard contentIDs.allSatisfy({ pendingContentMutations[$0] == nil }) else {
            throw ProjectStoreError.operationInProgress
        }
        let operationID = UUID()
        for id in contentIDs { pendingContentMutations[id] = operationID }
        contentRevision += 1
        invalidateContentDetails(Array(contentIDs))
        defer {
            let ownedIDs = contentIDs.filter { pendingContentMutations[$0] == operationID }
            for id in ownedIDs { pendingContentMutations[id] = nil }
            if !ownedIDs.isEmpty {
                contentRevision += 1
                invalidateContentDetails(Array(ownedIDs))
            }
            scheduleReconciliation()
        }
        do {
            try await operation()
            guard contentIDs.allSatisfy({ pendingContentMutations[$0] == operationID }) else { throw CancellationError() }
            apply()
            lastUpdated = Date()
        } catch {
            if contentIDs.allSatisfy({ pendingContentMutations[$0] == operationID }),
               requiresReconciliation(error) {
                for id in projectStates.keys { projectStates[id]?.needsRefresh = true }
            }
            throw error
        }
    }

    private func requiresReconciliation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case GitHubError.processError = error { return true }
        return false
    }

    private func refreshContentProjects(_ contentIDs: Set<String>) async throws {
        let ids = Set(contentIDs.flatMap { projectsContaining(contentID: $0) })
        var failure: Error?
        for id in ids.sorted() {
            do { try await refreshProjectSnapshot(id: id) }
            catch is CancellationError { throw CancellationError() }
            catch { failure = error }
        }
        if let failure { throw failure }
    }

    private func invalidateContentDetails(_ contentIDs: [String]) {
        for id in contentIDs {
            itemDetailTasks.removeValue(forKey: id)?.cancel()
            itemDetailEntries[id] = nil
            itemDetailGenerations[id, default: 0] += 1
        }
    }

    private func projectsContaining(contentID: String) -> [String] {
        projectStates.values.compactMap(\.snapshot).filter { project in
            project.items.contains { $0.contentId == contentID }
        }.map(\.id).sorted()
    }

    private func updateContent(contentID: String, transform: (inout ProjectItem) -> Void) {
        for id in projectsContaining(contentID: contentID) {
            guard var project = projectStates[id]?.snapshot else { continue }
            for index in project.items.indices where project.items[index].contentId == contentID {
                transform(&project.items[index])
            }
            projectStates[project.id]?.snapshot = project
        }
    }

    private func updateItem(
        projectID: String,
        itemID: String,
        transform: (inout ProjectItem) -> Void
    ) {
        guard var project = projectStates[projectID]?.snapshot,
              let itemIndex = project.items.firstIndex(where: { $0.id == itemID }) else { return }
        transform(&project.items[itemIndex])
        projectStates[project.id]?.snapshot = project
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


}
