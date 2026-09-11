import Foundation
import Testing
@testable import GitStride

@MainActor
struct ProjectStoreTests {
    @Test func managementPermissionsFollowTheLatestTargetSnapshot() async throws {
        let fields = Self.mutationFieldsResponse
        let runner = FixtureGitHubCommandRunner(responses: Self.mutationProjectResponses + [
            fields.replacingOccurrences(of: "\"viewerCanUpdate\":true", with: "\"viewerCanUpdate\":false"),
            Self.emptyItemsResponse,
            fields, Self.emptyItemsResponse
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()
        let oldSnapshot = try #require(store.selectedProject)
        #expect(store.canManageProject(id: oldSnapshot.id))
        await store.loadProjectDetails(id: oldSnapshot.id)
        #expect(oldSnapshot.viewerCanUpdate)
        #expect(!store.canManageProject(id: oldSnapshot.id))
        await store.loadProjectDetails(id: oldSnapshot.id)
        store.selectedProjectId = nil
        #expect(store.canManageProject(id: oldSnapshot.id))
        #expect(!store.canManageProject(id: "missing"))
    }

    @Test(arguments: [true, false])
    func deletionCommitsOnlyAfterGitHubSuccess(_ succeeds: Bool) async throws {
        let response = succeeds ? #"{"data":{"deleteProjectV2":{"clientMutationId":null}}}"#
                                : #"{"errors":[{"message":"Deletion denied"}]}"#
        let runner = FixtureGitHubCommandRunner(responses: Self.mutationProjectResponses + [response])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()
        let project = try #require(store.selectedProject)
        store.setFollowedProjects([FollowedProject(project: project)])
        do {
            try await store.deleteProject(id: project.id)
            #expect(succeeds)
        } catch let error as GitHubError {
            #expect(!succeeds)
            #expect(error == .graphQLError("Deletion denied"))
        }
        #expect(store.projects.isEmpty == succeeds)
        #expect((store.selectedProjectId == nil) == succeeds)
        #expect((store.followedProject(id: project.id) == nil) == succeeds)
        #expect(store.deletingProjectIDs.isEmpty)
        if succeeds {
            store.setFollowedProjects([FollowedProject(project: project)])
            #expect(store.project(id: project.id) == nil)
        }
        let calls = await runner.recordedArguments()
        #expect(calls.last?.contains("projectId=P1") == true)
    }

    @Test func catalogResponseCannotRestoreDeletedProject() async throws {
        let runner = SuspendingGitHubCommandRunner(steps: Self.mutationProjectResponses.map { .response($0) } + [
            .response(Self.sessionResponse), .response(Self.ownersResponse),
            .suspended("catalog", Self.mutationProjectsResponse),
            .response(#"{"data":{"deleteProjectV2":{"clientMutationId":null}}}"#)
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()
        let loading = Task { await store.loadProjects() }
        await runner.waitUntilSuspended("catalog")
        try await store.deleteProject(id: "P1")
        await runner.release("catalog")
        await loading.value
        #expect(store.projects.isEmpty)
        #expect(store.selectedProjectId == nil)
        #expect(!store.isLoading)
    }

    @Test func deletingSelectedProjectLoadsTheNextProject() async throws {
        let runner = FixtureGitHubCommandRunner(responses: [
            Self.sessionResponse, Self.ownersResponse, Self.projectsResponse,
            Self.firstProjectFieldsResponse, Self.emptyItemsResponse,
            #"{"data":{"deleteProjectV2":{"clientMutationId":null}}}"#,
            Self.firstProjectFieldsResponse, Self.emptyItemsResponse
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()
        try await store.deleteProject(id: "P1")
        #expect(store.projects.map(\.id) == ["P2"])
        #expect(store.selectedProjectId == "P2")
        guard case .empty(let project, _, _) = store.selectedProjectContentState else {
            Issue.record("Expected the next project to be loaded")
            return
        }
        #expect(project.id == "P2")
    }

    @Test func kanbanDefaultsToTheActiveWorkflowStatusesInPreferredOrder() {
        let runner = FixtureGitHubCommandRunner(responses: [])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        let project = Self.kanbanProject()

        #expect(store.visibleKanbanStatuses(in: project).map(\.name) == [
            "In Progress",
            "In Review",
            "Todo",
            "Backlog"
        ])
        #expect(project.statusOptions.map(\.name) == [
            "In Progress", "In Review", "Todo", "Backlog", "Done", "Canceled"
        ])
    }

    @Test func kanbanVisibilityCanShowAllButCannotHideTheFinalColumn() throws {
        let runner = FixtureGitHubCommandRunner(responses: [])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        let project = Self.kanbanProject()

        store.showAllKanbanStatuses(in: project)
        #expect(store.visibleKanbanStatuses(in: project).count == project.statusOptions.count)

        for status in project.statusOptions.dropLast() {
            store.setKanbanStatus(status, visible: false, in: project)
        }
        let finalStatus = try #require(project.statusOptions.last)
        store.setKanbanStatus(finalStatus, visible: false, in: project)

        #expect(store.visibleKanbanStatuses(in: project) == [finalStatus])
    }

    @Test func loadedEmptyProjectIsNotFetchedAgainWhenReselected() async throws {
        let runner = FixtureGitHubCommandRunner(responses: Self.emptyProjectResponses)
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }

        await store.loadProjects()
        let project = try #require(store.selectedProject)

        switch store.selectedProjectContentState {
        case .empty(let loadedProject, let isRefreshing, let isCached):
            #expect(loadedProject.id == project.id)
            #expect(isRefreshing == false)
            #expect(isCached == false)
        default:
            Issue.record("Expected a loaded, empty Project.")
        }

        let callCount = await runner.recordedArguments().count
        await store.selectProject(project)

        #expect(await runner.recordedArguments().count == callCount)
    }

    @Test func selectingAnotherProjectDiscardsThePreviousInFlightLoad() async throws {
        let runner = SuspendingGitHubCommandRunner(steps: [
            .response(Self.sessionResponse),
            .response(Self.ownersResponse),
            .response(Self.projectsResponse),
            .suspended("first-project", Self.firstProjectFieldsResponse),
            .response(Self.secondProjectFieldsResponse),
            .response(Self.emptyItemsResponse)
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }

        let initialLoad = Task { await store.loadProjects() }
        await runner.waitUntilSuspended("first-project")
        let secondProject = try #require(store.projects.first { $0.id == "P2" })

        await store.selectProject(secondProject)

        #expect(store.selectedProjectId == "P2")
        switch store.selectedProjectContentState {
        case .empty(let project, let isRefreshing, let isCached):
            #expect(project.id == "P2")
            #expect(isRefreshing == false)
            #expect(isCached == false)
        default:
            Issue.record("Expected the second Project to remain selected and loaded.")
        }

        await runner.release("first-project")
        await initialLoad.value

        #expect(store.selectedProjectId == "P2")
        #expect(store.operationErrorMessage == nil)
    }

    @Test func itemDetailLoadIsSharedWhileTheRequestIsInFlight() async {
        let response = Self.itemDetailResponse(body: "Shared")
        let runner = SuspendingGitHubCommandRunner(steps: [
            .suspended("item-detail", response)
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        let item = Self.detailItem(updatedAt: "2026-08-01T00:00:00Z")

        let firstLoad = Task { await store.loadItemDetail(for: item) }
        await runner.waitUntilSuspended("item-detail")
        let secondLoad = Task { await store.loadItemDetail(for: item) }
        await Task.yield()

        #expect(store.itemDetailState(for: item) == .loading)
        await runner.release("item-detail")
        await firstLoad.value
        await secondLoad.value

        #expect(await runner.recordedCallCount() == 1)
        #expect(store.itemDetailState(for: item) == .loaded(
            ProjectItemDetail(
                id: "CONTENT1",
                bodyHTML: "Shared",
                author: nil,
                createdAt: nil,
                updatedAt: "2026-08-01T00:00:00Z",
                issueMetadata: IssueMetadata(
                    repository: "acme/repo",
                    milestone: nil,
                    parent: nil,
                    subIssues: [],
                    subIssueProgress: nil,
                    blockedBy: [],
                    blocking: [],
                    viewerCanUpdate: false,
                    viewerCanSetMilestone: false
                )
            )
        ))
    }

    @Test func forcedItemDetailRefreshDiscardsTheOlderResponse() async {
        let runner = SuspendingGitHubCommandRunner(steps: [
            .suspended("old-detail", Self.itemDetailResponse(body: "Old")),
            .response(Self.itemDetailResponse(body: "New"))
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        let item = Self.detailItem(updatedAt: "2026-08-01T00:00:00Z")

        let oldLoad = Task { await store.loadItemDetail(for: item) }
        await runner.waitUntilSuspended("old-detail")
        await store.loadItemDetail(for: item, forceRefresh: true)
        await runner.release("old-detail")
        await oldLoad.value

        guard case .loaded(let detail) = store.itemDetailState(for: item) else {
            Issue.record("Expected the forced refresh result to remain loaded.")
            return
        }
        #expect(detail.bodyHTML == "New")
        #expect(await runner.recordedCallCount() == 2)
    }

    @Test func itemDetailCacheUsesTheItemUpdatedAtVersion() async {
        let runner = FixtureGitHubCommandRunner(responses: [
            Self.itemDetailResponse(body: "First"),
            Self.itemDetailResponse(body: "Updated")
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        let firstVersion = Self.detailItem(updatedAt: "2026-08-01T00:00:00Z")
        let secondVersion = Self.detailItem(updatedAt: "2026-08-02T00:00:00Z")

        await store.loadItemDetail(for: firstVersion)
        await store.loadItemDetail(for: firstVersion)
        await store.loadItemDetail(for: secondVersion)

        #expect(await runner.recordedArguments().count == 2)
        guard case .loaded(let detail) = store.itemDetailState(for: secondVersion) else {
            Issue.record("Expected the changed updatedAt value to reload details.")
            return
        }
        #expect(detail.bodyHTML == "Updated")
    }

    @Test func concurrentDeletesKeepBothItemsRemoved() async throws {
        let runner = SuspendingGitHubCommandRunner(steps: try Self.twoItemResponses().map { .response($0) } + [
            .suspended("first", Self.graphQLSuccessResponse),
            .suspended("second", Self.graphQLSuccessResponse)
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()
        let project = try #require(store.selectedProject)
        let first = try #require(project.items.first)
        let second = try #require(project.items.dropFirst().first)
        let firstTask = Task { try await store.deleteItem(first, from: project.id) }
        await runner.waitUntilSuspended("first")
        let secondTask = Task { try await store.deleteItem(second, from: project.id) }
        await runner.waitUntilSuspended("second")
        await runner.release("first")
        try await firstTask.value
        await runner.release("second")
        try await secondTask.value
        #expect(store.project(id: project.id)?.items.contains { $0.id == first.id || $0.id == second.id } == false)
    }

    @Test func staleRefreshCannotRestoreADeletedItemAndCoalescesReconciliation() async throws {
        let fields = Self.mutationFieldsResponse
        let runner = SuspendingGitHubCommandRunner(steps: Self.mutationProjectResponses.map { .response($0) } + [
            .suspended("old-read", fields), .response(Self.graphQLSuccessResponse),
            .response(Self.mutationItemsResponse),
            .suspended("reconcile", fields), .response(Self.emptyItemsResponse)
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()
        let project = try #require(store.selectedProject)
        let item = try #require(project.items.first)
        let refresh = Task { await store.refresh() }
        await runner.waitUntilSuspended("old-read")
        try await store.deleteItem(item, from: project.id)
        await runner.release("old-read")
        await refresh.value
        await runner.waitUntilSuspended("reconcile")
        #expect(store.project(id: project.id)?.items.isEmpty == true)
        let release = Task { await runner.release("reconcile") }
        await store.refresh()
        await release.value
        #expect(store.project(id: project.id)?.items.isEmpty == true)
        #expect(await runner.recordedCallCount() == 10)
    }

    @Test func supersededFailureCannotClearANewerLoadingState() async throws {
        let runner = SuspendingGitHubCommandRunner(steps: Self.mutationProjectResponses.map { .response($0) } + [
            .suspended("old-read", Self.graphQLFailureResponse),
            .suspended("new-read", Self.mutationFieldsResponse), .response(Self.emptyItemsResponse)
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()
        let project = try #require(store.selectedProject)
        let references = [FollowedProject(project: project)]
        store.setFollowedProjects(references)
        let old = Task { try await store.refreshMonitoredProjects(references) }
        await runner.waitUntilSuspended("old-read")
        let new = Task { await store.refresh() }
        await runner.waitUntilSuspended("new-read")
        await runner.release("old-read")
        #expect(try await old.value == nil)
        guard case .content(_, let refreshing, _) = store.selectedProjectContentState else {
            Issue.record("Expected the new request to retain its loading state")
            await runner.release("new-read")
            await new.value
            return
        }
        #expect(refreshing)
        await runner.release("new-read")
        await new.value
        #expect(store.selectedProject?.items.isEmpty == true)
    }

    @Test func monitorKeepsItsBaselineAcrossASupersededCycle() async throws {
        var project = Self.kanbanProject()
        var item = Self.detailItem(updatedAt: "2026-09-01")
        item.status = "Todo"
        project.items = [item]
        var changed = project
        changed.items[0].status = "Review"
        let source = MonitorSnapshotSource(cycles: [[project], nil, [changed]])
        let monitor = ProjectMonitor()
        let stream = await monitor.events(
            currentUserLogin: "me",
            policy: MonitoringPolicy(interval: .zero, quietStartHour: 0, quietEndHour: 0),
            readSnapshots: { try await source.next() }
        )
        var changes: [ProjectChange] = []
        for await event in stream {
            if case .change(let change) = event { changes.append(change) }
        }
        #expect(changes.count == 1)
        #expect(changes.first?.itemID == item.id)
    }

    @Test func removedAndRefollowedProjectRejectsItsPreviousRead() async throws {
        let fields = Self.mutationFieldsResponse
        let runner = SuspendingGitHubCommandRunner(steps: Self.mutationProjectResponses.map { .response($0) } + [
            .suspended("old-membership", fields), .suspended("new-membership", fields),
            .response(Self.mutationItemsResponse), .response(Self.emptyItemsResponse)
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()
        let first = try #require(store.selectedProject)
        let second = Project(id: "P2", owner: first.owner, title: "Two", number: 2, url: "", viewerCanUpdate: true)
        let reference = FollowedProject(project: second)
        store.setFollowedProjects([reference])
        let old = Task { try await store.refreshMonitoredProjects([reference]) }
        await runner.waitUntilSuspended("old-membership")
        store.setFollowedProjects([])
        store.setFollowedProjects([reference])
        let new = Task { await store.loadProjectDetails(id: "P2") }
        await runner.waitUntilSuspended("new-membership")
        await runner.release("old-membership")
        #expect(try await old.value == nil)
        #expect(store.project(id: "P2") == nil)
        await runner.release("new-membership")
        await new.value
        #expect(store.project(id: "P2")?.items.isEmpty == true)
    }
}

private actor MonitorSnapshotSource {
    private var cycles: [[Project]?]
    init(cycles: [[Project]?]) { self.cycles = cycles }
    func next() throws -> [Project]? {
        guard !cycles.isEmpty else { throw GitHubError.rateLimited(nil) }
        return cycles.removeFirst()
    }
}
