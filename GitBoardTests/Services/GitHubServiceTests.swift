import Foundation
import Testing
@testable import GitBoard

struct GitHubServiceTests {
    @Test func projectCatalogFollowsPagination() async throws {
        let runner = FixtureGitHubCommandRunner(responses: [
            """
            {"data":{"owner":{"projectsV2":{"nodes":[{"id":"P1","title":"One","number":1,"url":"https://github.com/users/me/projects/1","viewerCanUpdate":true}],"pageInfo":{"hasNextPage":true,"endCursor":"next"}}}}}
            """,
            """
            {"data":{"owner":{"projectsV2":{"nodes":[{"id":"P2","title":"Two","number":2,"url":"https://github.com/users/me/projects/2","viewerCanUpdate":false}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}
            """
        ])
        let service = GitHubService(runner: runner)
        let owner = ProjectOwner(id: "U1", login: "me", name: nil, kind: .user)

        let projects = try await service.fetchProjects(owner: owner)
        let calls = await runner.recordedArguments()

        #expect(projects.map(\.id) == ["P1", "P2"])
        #expect(projects[0].viewerCanUpdate)
        #expect(projects[1].viewerCanUpdate == false)
        #expect(calls.count == 2)
        #expect(calls[1].contains("after=next"))
    }

    @Test func projectLoadKeepsContentIdentityAndRedactedItems() async throws {
        let runner = FixtureGitHubCommandRunner(responses: [
            """
            {"data":{"node":{"title":"Work","number":7,"url":"https://github.com/users/me/projects/7","viewerCanUpdate":true,"fields":{"nodes":[{"__typename":"ProjectV2SingleSelectField","id":"F1","name":"Status","dataType":"SINGLE_SELECT","options":[{"id":"todo","name":"Todo","color":"GRAY"}]},{"__typename":"ProjectV2IterationField","id":"F2","name":"Iteration","dataType":"ITERATION","configuration":{"iterations":[{"id":"SPRINT1","title":"Sprint 1","startDate":"2026-08-24","duration":14}],"completedIterations":[]}},{"__typename":"ProjectV2Field","id":"F3","name":"Estimate","dataType":"NUMBER"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}
            """,
            """
            {"data":{"node":{"items":{"nodes":[{"id":"I1","content":{"__typename":"Issue","id":"CONTENT1","title":"First","number":1,"url":"https://github.com/acme/repo/issues/1","state":"OPEN","assignees":{"nodes":[]},"labels":{"nodes":[{"id":"L1","name":"bug","color":"d73a4a"}]},"closedByPullRequestsReferences":{"nodes":[]}},"fieldValueByName":{"name":"Todo","optionId":"todo"},"fieldValues":{"nodes":[{"__typename":"ProjectV2ItemFieldSingleSelectValue","name":"Todo","optionId":"todo","field":{"id":"F1"}},{"__typename":"ProjectV2ItemFieldIterationValue","title":"Sprint 1","iterationId":"SPRINT1","field":{"id":"F2"}},{"__typename":"ProjectV2ItemFieldNumberValue","number":3,"field":{"id":"F3"}}]}}],"pageInfo":{"hasNextPage":true,"endCursor":"items-next"}}}}}
            """,
            """
            {"data":{"node":{"items":{"nodes":[{"id":"I2","content":null,"fieldValueByName":null}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}
            """
        ])
        let service = GitHubService(runner: runner)
        let owner = ProjectOwner(id: "U1", login: "me", name: nil, kind: .user)
        let summary = Project(
            id: "P1",
            owner: owner,
            title: "Work",
            number: 7,
            url: "https://github.com/users/me/projects/7",
            viewerCanUpdate: true
        )

        let project = try await service.fetchProjectWithItems(project: summary)
        let calls = await runner.recordedArguments()

        #expect(project.items.count == 2)
        #expect(project.items[0].contentId == "CONTENT1")
        #expect(project.items[0].contentId != project.items[0].url)
        #expect(project.fields.map(\.kind) == [.singleSelect, .iteration, .number])
        #expect(project.items[0].labels.map(\.name) == ["bug"])
        #expect(project.items[0].fieldValues["F2"] == .iteration(id: "SPRINT1", title: "Sprint 1"))
        #expect(project.items[0].fieldValues["F3"] == .number(3))
        #expect(project.items[1].contentType == .redacted)
        #expect(calls[2].contains("after=items-next"))
    }

    @Test func sessionReportsMissingProjectScope() async {
        let runner = FixtureGitHubCommandRunner(responses: [
            """
            {"data":null,"errors":[{"message":"The projectsV2 field requires the project scope."}]}
            """
        ])
        let service = GitHubService(runner: runner)

        let state = await service.inspectSession()

        #expect(state == .missingProjectScope)
    }

    @Test func createdIssueIsExplicitlyAddedToProject() async throws {
        let runner = FixtureGitHubCommandRunner(responses: [
            "https://github.com/acme/widgets/issues/42\n",
            "ISSUE_NODE_42\n",
            """
            {"data":{"addProjectV2ItemById":{"item":{"id":"PROJECT_ITEM_42"}}}}
            """
        ])
        let service = GitHubService(runner: runner)

        try await service.createIssueAndAdd(
            projectId: "PROJECT_1",
            repository: "acme/widgets",
            title: "Repair login",
            labels: ["bug"],
            assignees: ["octocat"]
        )
        let calls = await runner.recordedArguments()

        #expect(calls.count == 3)
        #expect(calls[0].contains("acme/widgets"))
        #expect(calls[0].contains("Repair login"))
        #expect(calls[1].contains("repos/acme/widgets/issues/42"))
        #expect(calls[2].contains("contentId=ISSUE_NODE_42"))
        #expect(calls[2].contains("projectId=PROJECT_1"))
    }

}

struct ProjectCacheTests {
    @Test func roundTripPreservesTheDomainSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitBoardTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let owner = ProjectOwner(id: "U1", login: "octocat", name: "Octocat", kind: .user)
        let field = ProjectField(
            id: "F1",
            name: "Priority",
            kind: .singleSelect,
            options: [ProjectFieldOption(id: "HIGH", name: "High", color: "RED")],
            iterations: []
        )
        let item = ProjectItem(
            id: "I1",
            contentId: "C1",
            contentType: .issue,
            title: "Cached issue",
            number: 42,
            url: "https://github.com/acme/repo/issues/42",
            issueState: .open,
            prState: nil,
            status: "Todo",
            statusOptionId: "TODO",
            assignees: [],
            fieldValues: ["F1": .singleSelect(optionId: "HIGH", name: "High")]
        )
        let project = Project(
            id: "P1",
            owner: owner,
            title: "Work",
            number: 1,
            url: "https://github.com/users/octocat/projects/1",
            viewerCanUpdate: true,
            fields: [field],
            items: [item]
        )
        let cache = ProjectCache(fileURL: directory.appendingPathComponent("cache.json"))

        try await cache.save(
            ProjectCacheSnapshot(
                accountLogin: "octocat",
                owner: owner,
                projects: [project],
                selectedProjectId: "P1",
                selectedStatusFilter: "Todo"
            )
        )
        let loaded = try #require(try await cache.load())

        #expect(loaded.version == ProjectCacheSnapshot.currentVersion)
        #expect(loaded.accountLogin == "octocat")
        #expect(loaded.projects.first?.items.first?.title == "Cached issue")
        #expect(loaded.projects.first?.items.first?.fieldValues["F1"] == .singleSelect(optionId: "HIGH", name: "High"))
    }
}

struct MyWorkFilterTests {
    @Test func smartViewsKeepProjectContextAndApplyStableBoundaries() throws {
        let now = try Date("2026-08-27T00:00:00Z", strategy: .iso8601)
        let owner = ProjectOwner(id: "U1", login: "octocat", name: nil, kind: .user)
        let dueField = ProjectField(
            id: "DUE",
            name: "Due date",
            kind: .date,
            options: [],
            iterations: []
        )
        let item = ProjectItem(
            id: "ITEM",
            contentId: "CONTENT",
            contentType: .issue,
            title: "Blocked delivery",
            number: 7,
            url: "https://github.com/acme/repo/issues/7",
            issueState: .open,
            prState: nil,
            updatedAt: "2026-07-01T00:00:00Z",
            status: "Todo",
            statusOptionId: "TODO",
            assignees: [Assignee(login: "octocat", avatarUrl: "https://example.invalid/avatar", name: nil)],
            labels: [IssueLabel(id: "L1", name: "blocked", color: "ff0000")],
            fieldValues: ["DUE": .date("2026-08-30")]
        )
        let firstProject = Project(
            id: "P1",
            owner: owner,
            title: "First",
            number: 1,
            url: "https://github.com/users/octocat/projects/1",
            viewerCanUpdate: true,
            fields: [dueField],
            items: [item]
        )
        let secondProject = Project(
            id: "P2",
            owner: owner,
            title: "Second",
            number: 2,
            url: "https://github.com/users/octocat/projects/2",
            viewerCanUpdate: true,
            fields: [dueField],
            items: [item]
        )
        let workItem = MyWorkItem(project: firstProject, item: item)

        #expect(MyWorkFilter.assigned.includes(workItem, currentUserLogin: "octocat", now: now))
        #expect(MyWorkFilter.due.includes(workItem, currentUserLogin: nil, now: now))
        #expect(MyWorkFilter.blocked.includes(workItem, currentUserLogin: nil, now: now))
        #expect(MyWorkFilter.stale.includes(workItem, currentUserLogin: nil, now: now))
        #expect(MyWorkFilter.recent.includes(workItem, currentUserLogin: nil, now: now) == false)
        #expect(workItem.id != MyWorkItem(project: secondProject, item: item).id)
    }
}

private actor FixtureGitHubCommandRunner: GitHubCommandRunning {
    private var responses: [Data]
    private var calls: [[String]] = []

    init(responses: [String]) {
        self.responses = responses.map { Data($0.utf8) }
    }

    func run(arguments: [String]) async throws -> GitHubCommandResult {
        calls.append(arguments)
        guard responses.isEmpty == false else {
            throw FixtureError.missingResponse
        }
        return GitHubCommandResult(
            standardOutput: responses.removeFirst(),
            standardError: Data()
        )
    }

    func recordedArguments() -> [[String]] {
        calls
    }

    private enum FixtureError: Error {
        case missingResponse
    }
}
