import Foundation
import Testing
@testable import GitStride

extension ProjectStoreTests {
    @Test func itemRejectsASecondStatusMoveWhileOneIsPending() async throws {
        let runner = SuspendingGitHubHTTPClient(steps:
            Self.mutationProjectResponses.map { .response($0) } + [
                .suspended("status-move", Self.graphQLSuccessResponse)
            ]
        )
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()

        let project = try #require(store.selectedProject)
        let item = try #require(project.items.first)
        let review = try #require(project.statusOptions.first { $0.id == "REVIEW" })
        let firstMove = Task { try await store.moveItem(item, toStatus: review, in: project.id) }
        await runner.waitUntilSuspended("status-move")
        let callCount = await runner.recordedCallCount()

        await #expect(throws: ProjectStoreError.self) {
            try await store.moveItem(item, toStatus: review, in: project.id)
        }

        #expect(await runner.recordedCallCount() == callCount)
        await runner.release("status-move")
        try await firstMove.value
        #expect(store.project(id: project.id)?.items.first?.status == "Review")
    }

    @Test func archiveKeepsAnotherItemsCompletedStatusMove() async throws {
        let runner = SuspendingGitHubHTTPClient(steps: try Self.twoItemResponses().map { .response($0) } + [
            .suspended("archive", Self.graphQLSuccessResponse), .response(Self.graphQLSuccessResponse)
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()
        let project = try #require(store.selectedProject)
        let first = try #require(project.items.first)
        let second = try #require(project.items.dropFirst().first)
        let status = try #require(project.statusOptions.first)
        let archive = Task { try await store.archiveItem(first, in: project.id) }
        await runner.waitUntilSuspended("archive")
        try await store.moveItem(second, toStatus: status, in: project.id)
        await runner.release("archive")
        try await archive.value
        #expect(store.project(id: project.id)?.items.first { $0.id == second.id }?.statusOptionId == status.id)
    }

    @Test func contentChangesReachEveryProjectAndKeepProjectStatusIndependent() async throws {
        let fields = Self.mutationFieldsResponse
        let items = Self.mutationItemsResponse.replacingOccurrences(
            of: "\"labels\":{\"nodes\":[]}",
            with: "\"labels\":{\"nodes\":[{\"id\":\"L1\",\"name\":\"bug\",\"color\":\"ffffff\"}]}"
        )
        let runner = FixtureGitHubHTTPClient(responses: Self.mutationProjectResponses + [
            fields, Self.mutationItemsResponse, fields,
            Self.mutationItemsResponse.replacingOccurrences(of: "Todo", with: "Review")
                .replacingOccurrences(of: "TODO", with: "REVIEW"),
            "", "", fields, items, fields, items.replacingOccurrences(of: "Todo", with: "Review")
                .replacingOccurrences(of: "TODO", with: "REVIEW")
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()
        let first = try #require(store.project(id: "P1"))
        var second = Project(id: "P2", owner: first.owner, title: first.title, number: 2,
                             url: "", viewerCanUpdate: first.viewerCanUpdate,
                             fields: first.fields, statusField: first.statusField, items: first.items)
        second.items[0].status = "Review"
        second.items[0].statusOptionId = "REVIEW"
        await store.refreshFollowedProjects([FollowedProject(project: first), FollowedProject(project: second)])
        let item = try #require(first.items.first)
        let user = Assignee(login: "octocat", avatarUrl: "", name: nil)
        try await store.addAssignee(to: item, in: "P1", user: user)
        #expect(store.project(id: "P1")?.items.first?.assignees == [user])
        #expect(store.project(id: "P2")?.items.first?.assignees == [user])
        #expect(store.project(id: "P2")?.items.first?.status == "Review")
        try await store.addLabel(to: item, in: "P1", name: "bug")
        #expect(store.project(id: "P1")?.items.first?.labels.map(\.name) == ["bug"])
        #expect(store.project(id: "P2")?.items.first?.labels.map(\.name) == ["bug"])
        #expect(store.project(id: "P1")?.items.first?.status == "Todo")
        #expect(store.project(id: "P2")?.items.first?.status == "Review")
    }

    @Test(arguments: [true, false])
    func milestoneChangesUpdateDeliveryInEveryLoadedProject(_ clearsMilestone: Bool) async throws {
        let milestoneA = #"{"id":"M1","number":1,"title":"Milestone A","dueOn":null,"state":"OPEN","progressPercentage":100}"#
        let milestoneB = #"{"id":"M2","number":2,"title":"Milestone B","dueOn":null,"state":"OPEN","progressPercentage":100}"#
        let updatedMilestone = clearsMilestone ? "null" : milestoneB
        func itemsResponse(milestone: String, secondProject: Bool = false) -> String {
            let response = Self.mutationItemsResponse.replacingOccurrences(
                of: #""state":"OPEN""#,
                with: #""state":"CLOSED","milestone":\#(milestone)"#
            )
            let versioned = milestone == milestoneA ? response : response.replacingOccurrences(
                of: "2026-08-01T00:00:00Z", with: "2026-08-02T00:00:00Z"
            )
            return secondProject ? versioned.replacingOccurrences(of: "ITEM1", with: "ITEM2")
                .replacingOccurrences(of: "Todo", with: "Review")
                .replacingOccurrences(of: "TODO", with: "REVIEW") : versioned
        }
        func detailResponse(milestone: String) -> String {
            Self.itemDetailResponse(body: "Milestone details")
                .replacingOccurrences(of: #""viewerCanSetMilestone":false"#, with: #""viewerCanSetMilestone":true"#)
                .replacingOccurrences(of: #""milestone":null"#, with: #""milestone":\#(milestone)"#)
                .replacingOccurrences(of: "acme/repo", with: "acme/app")
        }
        let fields = Self.mutationFieldsResponse
        let runner = FixtureGitHubHTTPClient(responses: [
            Self.sessionResponse, Self.ownersResponse, Self.projectsResponse,
            fields, itemsResponse(milestone: milestoneA),
            fields, itemsResponse(milestone: milestoneA, secondProject: true),
            detailResponse(milestone: milestoneA),
            #"{"data":{"updateIssue":{"issue":{"id":"CONTENT1"}}}}"#,
            fields, itemsResponse(milestone: updatedMilestone),
            fields, itemsResponse(milestone: updatedMilestone, secondProject: true),
            detailResponse(milestone: updatedMilestone)
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()
        await store.loadProjectDetails(id: "P2")
        let item = try #require(store.project(id: "P1")?.items.first)
        await store.loadItemDetail(for: item)
        let filterA = ProjectWorkFilter(milestoneID: "M1")
        let filterB = ProjectWorkFilter(milestoneID: "M2")
        for projectID in ["P1", "P2"] {
            let project = try #require(store.project(id: projectID))
            #expect(filterA.deliveryItems(in: project.items).count == 1)
            #expect(filterB.deliveryItems(in: project.items).isEmpty)
        }

        let target = clearsMilestone ? nil : RepositoryMilestone(
            id: "M2", number: 2, title: "Milestone B", dueOn: nil, state: .open, progressPercentage: 100
        )
        try await store.setMilestone(target, on: item)

        let refreshedItem = try #require(store.project(id: "P1")?.items.first)
        guard case .loaded(let detail) = store.itemDetailState(for: refreshedItem) else {
            Issue.record("Expected refreshed milestone details")
            return
        }
        #expect(detail.issueMetadata?.milestone?.id == target?.id)
        for projectID in ["P1", "P2"] {
            let project = try #require(store.project(id: projectID))
            let updatedItem = try #require(project.items.first)
            #expect(updatedItem.milestone?.id == target?.id)
            #expect(updatedItem.status == (projectID == "P1" ? "Todo" : "Review"))
            #expect(filterA.apply(to: project.items, currentUserLogin: nil).isEmpty)
            #expect(filterA.deliveryItems(in: project.items).isEmpty)
            let expectedIDs = clearsMilestone ? [] : [updatedItem.id]
            #expect(filterB.apply(to: project.items, currentUserLogin: nil).map(\.id) == expectedIDs)
            let delivery = filterB.deliveryItems(in: project.items)
            #expect(delivery.count == expectedIDs.count)
            #expect(delivery.filter(\.isWorkComplete).count == expectedIDs.count)
        }
    }

    @Test func contentMutationInvalidatesAProjectWhoseMembershipWasNotLoadedYet() async throws {
        let fields = Self.mutationFieldsResponse
        let updatedItems = Self.mutationItemsResponse.replacingOccurrences(
            of: "\"assignees\":{\"nodes\":[]}",
            with: "\"assignees\":{\"nodes\":[{\"login\":\"octocat\",\"avatarUrl\":\"\",\"name\":null}]}"
        )
        let runner = SuspendingGitHubHTTPClient(steps: Self.mutationProjectResponses.map { .response($0) } + [
            .suspended("new-project", fields), .response(""),
            .response(Self.mutationItemsResponse),
            .suspended("reconcile", fields), .response(updatedItems)
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()
        let first = try #require(store.selectedProject)
        let second = Project(id: "P2", owner: first.owner, title: "Two", number: 2, url: "", viewerCanUpdate: true)
        store.setFollowedProjects([FollowedProject(project: first), FollowedProject(project: second)])
        let loading = Task { await store.loadProjectDetails(id: "P2") }
        await runner.waitUntilSuspended("new-project")
        let item = try #require(first.items.first)
        let user = Assignee(login: "octocat", avatarUrl: "", name: nil)
        try await store.addAssignee(to: item, in: first.id, user: user)
        await runner.release("new-project")
        await loading.value
        await runner.waitUntilSuspended("reconcile")
        #expect(store.project(id: "P2") == nil)
        let release = Task { await runner.release("reconcile") }
        await store.loadProjectDetails(id: "P2")
        await release.value
        #expect(store.project(id: "P2")?.items.first?.assignees == [user])
    }

    @Test func optimisticStatusIsSharedButNeverCachedAndConflictsWithFieldEdits() async throws {
        let runner = SuspendingGitHubHTTPClient(steps: Self.mutationProjectResponses.map { .response($0) } + [
            .suspended("status", Self.graphQLFailureResponse), .response("")
        ])
        let identifier = "GitStrideTests.Optimistic.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: identifier))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
        let cache = ProjectCache(fileURL: url)
        defer {
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: url)
        }
        let store = ProjectStore(gitHubService: GitHubService(http: runner), projectCache: cache, defaults: defaults)
        await store.loadProjects()
        let project = try #require(store.selectedProject)
        let item = try #require(project.items.first)
        let field = try #require(project.fields.first)
        let review = try #require(project.statusOptions.first { $0.id == "REVIEW" })
        store.setFollowedProjects([FollowedProject(project: project)])
        let moving = Task { try await store.moveItem(item, toStatus: review, in: project.id) }
        await runner.waitUntilSuspended("status")
        #expect(store.selectedProject?.items.first?.status == "Review")
        #expect(store.allProjects.first?.items.first?.status == "Review")
        #expect(store.followedProject(id: project.id)?.items.first?.status == "Review")
        await #expect(throws: ProjectStoreError.self) {
            try await store.updateField(on: item, in: project.id, field: field,
                                        value: .singleSelect(optionId: "TODO", name: "Todo"))
        }
        let user = Assignee(login: "octocat", avatarUrl: "", name: nil)
        try await store.addAssignee(to: item, in: project.id, user: user)
        let snapshot = try #require(try await cache.load())
        #expect(snapshot.projects.first?.items.first?.status == "Todo")
        #expect(snapshot.projects.first?.items.first?.assignees == [user])
        await runner.release("status")
        await #expect(throws: GitHubError.self) { try await moving.value }
        #expect(store.selectedProject?.items.first?.status == "Todo")
        #expect(store.selectedProject?.items.first?.statusOptionId == "TODO")
        #expect(store.selectedProject?.items.first?.assignees == [user])
    }

    @Test func contentMutationInvalidatesAnInFlightDetailRead() async throws {
        let runner = SuspendingGitHubHTTPClient(steps: Self.mutationProjectResponses.map { .response($0) } + [
            .suspended("old-detail", Self.itemDetailResponse(body: "Old")), .response(""),
            .response(Self.itemDetailResponse(body: "Updated"))
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()
        let project = try #require(store.selectedProject)
        let item = try #require(project.items.first)
        let loading = Task { await store.loadItemDetail(for: item) }
        await runner.waitUntilSuspended("old-detail")
        try await store.addAssignee(to: item, in: project.id, user: Assignee(login: "me", avatarUrl: "", name: nil))
        await runner.release("old-detail")
        await loading.value
        #expect(store.itemDetailState(for: item) == .idle)
        await store.loadItemDetail(for: item)
        guard case .loaded(let detail) = store.itemDetailState(for: item) else {
            Issue.record("Expected details to be fetched after content mutation")
            return
        }
        #expect(detail.bodyHTML == "Updated")
    }
}
