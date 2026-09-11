import Foundation
import Testing
@testable import GitStride

extension ProjectStoreTests {
    @Test func creationRejectsRepositoryFromAnotherOwner() async throws {
        let runner = FixtureGitHubCommandRunner(responses: [])
        let store = ProjectStore(gitHubService: GitHubService(runner: runner))
        let owner = ProjectOwner(id: "OWNER", login: "me", name: nil, kind: .user)
        do {
            try await store.createProject(
                owner: owner, title: "Project",
                repository: ProjectRepository(id: "R", nameWithOwner: "other/repo", ownerID: "OTHER")
            )
            Issue.record("Expected a repository ownership error")
        } catch ProjectStoreError.repositoryOwnerMismatch {}
        #expect(await runner.recordedArguments().isEmpty)
        #expect(!store.isCreatingProject)
    }

    @Test func createdProjectSurvivesFollowupReadFailure() async throws {
        let runner = FixtureGitHubCommandRunner(responses: [
            Self.createdProjectResponse,
            #"{"errors":[{"message":"List unavailable"}]}"#,
            #"{"errors":[{"message":"Details unavailable"}]}"#
        ])
        let suite = "CreateProjectTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(gitHubService: GitHubService(runner: runner), defaults: defaults)
        let owner = ProjectOwner(id: "OWNER", login: "me", name: nil, kind: .user)
        try await store.createProject(owner: owner, title: "New project")
        #expect(store.selectedProjectId == "NEW")
        #expect(store.selectedOwnerId == "OWNER")
        #expect(store.projects.map(\.id) == ["NEW"])
        #expect(!store.isCreatingProject)
        #expect(!store.isLoading)
        #expect(store.operationErrorMessage != nil)
        #expect(await runner.recordedArguments().count == 3)
    }

    @Test func createdIssueFinishesInOriginalProjectAndRetryDoesNotRecreateIt() async throws {
        let fields = Self.mutationFieldsResponse
        let items = Self.mutationItemsResponse
        let runner = SuspendingGitHubCommandRunner(steps: Self.mutationProjectResponses.map { .response($0) } + [
            .suspended("create", "https://github.com/acme/app/issues/1"),
            .response("CONTENT1"), .response(Self.graphQLSuccessResponse),
            .response(fields), .response(items), .response(Self.graphQLFailureResponse),
            .response(fields), .response(items), .response(Self.graphQLSuccessResponse),
            .response(fields), .response(items)
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()
        let operation = try store.prepareIssueCreation(repository: "acme/app", title: "New", body: "",
                                                       labels: [], assignees: [], status: "Review")
        let creation = Task { try await store.resumeIssueCreation(operation) }
        await runner.waitUntilSuspended("create")
        do {
            try await store.resumeIssueCreation(operation)
            Issue.record("Expected a concurrent submission to be rejected")
        } catch {
            guard case ProjectStoreError.operationInProgress = error else { throw error }
        }
        store.selectedProjectId = "P2"
        await runner.release("create")
        do {
            try await creation.value
            Issue.record("Expected field failure with a resumable issue")
        } catch {
            #expect(operation.projectID == "P1")
            #expect(operation.phase == .applyingFields(issueURL: "https://github.com/acme/app/issues/1"))
            try await store.resumeIssueCreation(operation)
        }
        #expect(operation.phase == .completed(issueURL: "https://github.com/acme/app/issues/1"))
        let calls = await runner.recordedArguments()
        #expect(calls.filter { $0.starts(with: ["issue", "create"]) }.count == 1)
        #expect(calls.filter { $0.contains("optionId=REVIEW") }.count == 2)
        #expect(calls.filter { $0.contains("optionId=REVIEW") }.allSatisfy { $0.contains("projectId=P1") && $0.contains("itemId=ITEM1") })
        #expect(store.selectedProjectId == "P2")
    }

    @Test func createdIssueResumesAddingToItsOriginalProject() async throws {
        let fields = Self.mutationFieldsResponse
        let items = Self.mutationItemsResponse
        let runner = FixtureGitHubCommandRunner(responses: Self.mutationProjectResponses + [
            "https://github.com/acme/app/issues/1", "CONTENT1", Self.graphQLFailureResponse,
            "CONTENT1", Self.graphQLSuccessResponse, fields, items,
            Self.graphQLSuccessResponse, fields, items
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()
        let operation = try store.prepareIssueCreation(repository: "acme/app", title: "New", body: "",
                                                       labels: [], assignees: [], status: "Review")
        do {
            try await store.resumeIssueCreation(operation)
            Issue.record("Expected membership failure")
        } catch {
            #expect(operation.phase == .addingToProject(issueURL: "https://github.com/acme/app/issues/1"))
            #expect(operation.canResume)
        }
        store.selectedProjectId = "P2"
        try await store.resumeIssueCreation(operation)
        try await store.resumeIssueCreation(operation)
        #expect(operation.phase == .completed(issueURL: "https://github.com/acme/app/issues/1"))
        let calls = await runner.recordedArguments()
        #expect(calls.filter { $0.starts(with: ["issue", "create"]) }.count == 1)
        let additions = calls.filter { $0.contains("contentId=CONTENT1") }
        #expect(additions.count == 2)
        #expect(additions.allSatisfy { $0.contains("projectId=P1") })
        #expect(calls.filter { $0.contains("optionId=REVIEW") }.count == 1)
        #expect(store.selectedProjectId == "P2")
    }

    @Test func creationRetriesOnlyUnfinishedFieldsAndThenOnlyTheRefresh() async throws {
        let priority = #"{"__typename":"ProjectV2SingleSelectField","id":"PRIORITY","name":"Priority","dataType":"SINGLE_SELECT","options":[{"id":"HIGH","name":"High","color":"RED"}]},"#
        let fields = Self.mutationFieldsResponse.replacingOccurrences(
            of: #""fields":{"nodes":["#, with: #""fields":{"nodes":[\#(priority)"#
        )
        let items = Self.mutationItemsResponse
        var initial = Self.mutationProjectResponses
        initial[3] = fields
        let runner = FixtureGitHubCommandRunner(responses: initial + [
            "https://github.com/acme/app/issues/1", "CONTENT1", Self.graphQLSuccessResponse,
            fields, items, Self.graphQLSuccessResponse, Self.graphQLFailureResponse,
            fields, items, Self.graphQLSuccessResponse, Self.graphQLFailureResponse,
            fields, items
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()
        let operation = try store.prepareIssueCreation(repository: "acme/app", title: "New", body: "",
                                                       labels: [], assignees: [], status: "Review", priority: "High")
        do {
            try await store.resumeIssueCreation(operation)
            Issue.record("Expected the second field to fail")
        } catch {
            #expect(operation.phase == .applyingFields(issueURL: "https://github.com/acme/app/issues/1"))
        }
        do {
            try await store.resumeIssueCreation(operation)
            Issue.record("Expected the final refresh to fail")
        } catch {
            #expect(operation.phase == .refreshingProject(issueURL: "https://github.com/acme/app/issues/1"))
        }
        try await store.resumeIssueCreation(operation)
        #expect(operation.phase == .completed(issueURL: "https://github.com/acme/app/issues/1"))
        let calls = await runner.recordedArguments()
        #expect(calls.filter { $0.starts(with: ["issue", "create"]) }.count == 1)
        #expect(calls.filter { $0.contains("contentId=CONTENT1") }.count == 1)
        #expect(calls.filter { $0.contains("optionId=REVIEW") }.count == 1)
        #expect(calls.filter { $0.contains("optionId=HIGH") }.count == 2)
    }

    @Test func creationWithoutAConfirmedIdentityCannotBeResubmitted() async throws {
        let runner = FixtureGitHubCommandRunner(responses: Self.mutationProjectResponses + [""])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()
        let operation = try store.prepareIssueCreation(repository: "acme/app", title: "New", body: "",
                                                       labels: [], assignees: [])
        for _ in 0..<2 {
            do {
                try await store.resumeIssueCreation(operation)
                Issue.record("Expected an unconfirmed creation result")
            } catch {
                #expect((error as? GitHubError) == .issueCreationUnconfirmed)
            }
        }
        #expect(operation.phase == .unconfirmed)
        #expect(!operation.canResume)
        #expect(await runner.recordedArguments().filter { $0.starts(with: ["issue", "create"]) }.count == 1)
    }

    @Test(arguments: [true, false])
    func interruptedCreationKeepsItsOutcomeUnconfirmed(_ cancelled: Bool) async throws {
        let runner = SuspendingGitHubCommandRunner(steps: Self.mutationProjectResponses.map { .response($0) } + [
            cancelled ? .cancelled : .failure(.timedOut),
            .suspended("reconcile", Self.mutationFieldsResponse), .response(Self.mutationItemsResponse)
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()
        let operation = try store.prepareIssueCreation(repository: "acme/app", title: "New", body: "",
                                                       labels: [], assignees: [])
        do {
            try await store.resumeIssueCreation(operation)
            Issue.record("Expected an interrupted creation")
        } catch {
            #expect(operation.phase == .unconfirmed)
            #expect(!operation.canResume)
            #expect(operation.errorMessage?.contains("Check the repository") == true)
        }
        await runner.waitUntilSuspended("reconcile")
        let release = Task { await runner.release("reconcile") }
        await store.loadProjectDetails(id: "P1")
        await release.value
        do {
            try await store.resumeIssueCreation(operation)
            Issue.record("Expected resubmission to be blocked")
        } catch {
            #expect((error as? GitHubError) == .issueCreationUnconfirmed)
        }
        #expect(await runner.recordedArguments().filter { $0.starts(with: ["issue", "create"]) }.count == 1)
    }
}
