import Foundation
import Testing
@testable import GitStride

struct GitHubServiceTests {
    private static let createdProjectResponse = """
        {"data":{"createProjectV2":{"projectV2":{"id":"NEW","title":"New project","number":9,"url":"https://github.com/users/me/projects/9","viewerCanUpdate":true}}}}
        """

    @Test(arguments: [ProjectOwnerKind.user, .organization], [nil, "REPO"] as [String?])
    func createsProjectForSelectedOwner(_ kind: ProjectOwnerKind, repositoryID: String?) async throws {
        let runner = FixtureGitHubCommandRunner(responses: [Self.createdProjectResponse])
        let owner = ProjectOwner(id: "OWNER", login: "me", name: nil, kind: kind)
        let title = "Plan \"Q4\"\n新项目"
        let project = try await GitHubService(runner: runner).createProject(owner: owner, title: title, repositoryID: repositoryID)
        #expect(project.id == "NEW")
        #expect(project.owner == owner)
        #expect(project.number == 9)
        #expect(project.viewerCanUpdate)
        let arguments = try #require(await runner.recordedArguments().first)
        #expect(arguments.contains("ownerId=OWNER"))
        #expect(arguments.contains("title=\(title)"))
        #expect(arguments.contains("repositoryId=REPO") == (repositoryID != nil))
    }

    @Test func repositoryChoicesFollowPagination() async throws {
        let runner = FixtureGitHubCommandRunner(responses: [
            #"{"data":{"repositoryOwner":{"repositories":{"nodes":[{"id":"R1","nameWithOwner":"me/one"}],"pageInfo":{"hasNextPage":true,"endCursor":"next"}}}}}"#,
            #"{"data":{"repositoryOwner":{"repositories":{"nodes":[{"id":"R2","nameWithOwner":"me/two"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#
        ])
        let owner = ProjectOwner(id: "OWNER", login: "me", name: nil, kind: .user)
        let repositories = try await GitHubService(runner: runner).fetchRepositories(owner: owner)
        #expect(repositories.map(\.id) == ["R1", "R2"])
        #expect(repositories.allSatisfy { $0.ownerID == owner.id })
        let calls = await runner.recordedArguments()
        #expect(calls[1].contains("after=next"))
        #expect(calls[0].contains("login=me"))
    }

    @Test(arguments: [true, false])
    func linkingRepositoryReportsGitHubOutcome(_ succeeds: Bool) async throws {
        let runner = FixtureGitHubCommandRunner(responses: [
            succeeds ? #"{"data":{"linkProjectV2ToRepository":{"repository":{"id":"R1"}}}}"#
                     : #"{"errors":[{"message":"Link permission denied"}]}"#
        ])
        do {
            try await GitHubService(runner: runner).linkProjectRepository(projectID: "P1", repositoryID: "R1")
            #expect(succeeds)
        } catch let error as GitHubError {
            #expect(!succeeds)
            #expect(error == .graphQLError("Link permission denied"))
        }
        let calls = await runner.recordedArguments()
        #expect(calls.count == 1)
        #expect(calls[0].contains("projectId=P1"))
        #expect(calls[0].contains("repositoryId=R1"))
    }

    @Test @MainActor func creationRejectsRepositoryFromAnotherOwner() async throws {
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

    @Test @MainActor func createdProjectSurvivesFollowupReadFailure() async throws {
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

    @Test func processWritesInputAndClosesItWhileDrainingOutput() async throws {
        let runner = ProcessGitHubCommandRunner(executableURL: URL(fileURLWithPath: "/bin/cat"))
        let input = Data(repeating: 65, count: 256 * 1024)
        let result = try await runner.run(arguments: [], standardInput: input)
        #expect(result.standardOutput == input)
    }

    @Test(arguments: [3.0, 2.5, 0.0]) func numberFieldsUseJSONNumbers(_ value: Double) async throws {
        let runner = FixtureGitHubCommandRunner(responses: [#"{"data":{}}"#])
        try await GitHubService(runner: runner).updateItemField(
            projectId: "P", itemId: "I", fieldId: "F", value: .number(value)
        )
        let input = try #require(await runner.recordedInputs().first ?? nil)
        let body = try #require(JSONSerialization.jsonObject(with: input) as? [String: Any])
        let variables = try #require(body["variables"] as? [String: Any])
        #expect(variables["number"] is String == false)
        #expect((variables["number"] as? NSNumber)?.doubleValue == value)
        #expect(await runner.recordedArguments() == [["api", "graphql", "--input", "-"]])
    }

    @Test(arguments: ["The project scope is required", "API rate limit exceeded", "plain failure"])
    func processFailurePreservesGraphQLErrors(_ message: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("gh")
        let script = "#!/bin/sh\nprintf '%s' '{\"data\":null,\"errors\":[{\"message\":\"" + message + "\"}]}'\nprintf '%s' 'command failed' >&2\nexit 1\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runner = ProcessGitHubCommandRunner(executableURL: executable)
        do {
            _ = try await GitHubService(runner: runner).fetchProjects(
                owner: ProjectOwner(id: "U", login: "me", name: nil, kind: .user)
            )
            Issue.record("Expected a structured error")
        } catch let error as GitHubError {
            switch (message, error) {
            case ("The project scope is required", .missingProjectScope),
                 ("API rate limit exceeded", .rateLimited),
                 ("plain failure", .graphQLError): break
            default: Issue.record("Incorrect error classification")
            }
        }
    }

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
            {"data":{"node":{"items":{"nodes":[{"id":"I1","content":{"__typename":"Issue","id":"CONTENT1","title":"First","number":1,"url":"https://github.com/acme/repo/issues/1","state":"OPEN","assignees":{"nodes":[]},"labels":{"nodes":[{"id":"L1","name":"bug","color":"d73a4a"}]},"closedByPullRequestsReferences":{"nodes":[]},"subIssuesSummary":{"completed":2,"total":3},"blockedBy":{"totalCount":1},"blocking":{"totalCount":4}},"fieldValueByName":{"name":"Todo","optionId":"todo"},"fieldValues":{"nodes":[{"__typename":"ProjectV2ItemFieldSingleSelectValue","name":"Todo","optionId":"todo","field":{"id":"F1"}},{"__typename":"ProjectV2ItemFieldIterationValue","title":"Sprint 1","iterationId":"SPRINT1","field":{"id":"F2"}},{"__typename":"ProjectV2ItemFieldNumberValue","number":3,"field":{"id":"F3"}},{"__typename":"ProjectV2ItemFieldRepositoryValue"}]}}],"pageInfo":{"hasNextPage":true,"endCursor":"items-next"}}}}}
            """,
            """
            {"data":{"node":{"items":{"nodes":[{"id":"I2","content":{"__typename":"PullRequest","id":"PR1","title":"Merge safely","number":2,"url":"https://github.com/acme/repo/pull/2","state":"OPEN","updatedAt":"2026-08-27T00:00:00Z","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","reviewRequests":{"nodes":[{"requestedReviewer":{"login":"octocat"}}]},"statusCheckRollup":{"state":"SUCCESS"},"assignees":{"nodes":[]},"labels":{"nodes":[]}},"fieldValueByName":{"name":"Todo","optionId":"todo"},"fieldValues":{"nodes":[]}},{"id":"I3","content":null,"fieldValueByName":null}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}
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

        let project = try await service.fetchProjectWithItems(id: summary.id, owner: summary.owner)
        let calls = await runner.recordedArguments()

        #expect(project.items.count == 3)
        #expect(project.items[0].contentId == "CONTENT1")
        #expect(project.items[0].contentId != project.items[0].url)
        #expect(project.fields.map(\.kind) == [.singleSelect, .iteration, .number])
        #expect(project.items[0].labels.map(\.name) == ["bug"])
        #expect(project.items[0].signals.subIssueProgress == SubIssueProgress(completed: 2, total: 3))
        #expect(project.items[0].signals.blockedByCount == 1)
        #expect(project.items[0].signals.blockingCount == 4)
        #expect(project.items[0].fieldValues["F2"] == .iteration(id: "SPRINT1", title: "Sprint 1"))
        #expect(project.items[0].fieldValues["F3"] == .number(3))
        #expect(project.items[1].signals.isReadyToMerge)
        #expect(project.items[1].signals.reviewRequested(for: "octocat"))
        #expect(project.items[2].contentType == .redacted)
        #expect(calls[2].contains("after=items-next"))
    }

    @Test func projectItemQueryRequestsTypeForEveryFieldValue() {
        let selectionPattern = #"fieldValues\(first: 100\) \{\s*nodes \{\s*__typename"#

        #expect(
            GraphQLQueries.projectItems.range(
                of: selectionPattern,
                options: .regularExpression
            ) != nil
        )
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

        let issueURL = try await service.createIssueAndAdd(
            projectId: "PROJECT_1",
            repository: "acme/widgets",
            title: "Repair login",
            body: "Login fails after token refresh.",
            labels: ["bug"],
            assignees: ["octocat"]
        )
        let calls = await runner.recordedArguments()

        #expect(issueURL == "https://github.com/acme/widgets/issues/42")
        #expect(calls.count == 3)
        #expect(calls[0].contains("acme/widgets"))
        #expect(calls[0].contains("Repair login"))
        let bodyFlagIndex = try #require(calls[0].firstIndex(of: "--body"))
        try #require(calls[0].indices.contains(bodyFlagIndex + 1))
        #expect(calls[0][bodyFlagIndex + 1] == "Login fails after token refresh.")
        #expect(calls[1].contains("repos/acme/widgets/issues/42"))
        #expect(calls[2].contains("contentId=ISSUE_NODE_42"))
        #expect(calls[2].contains("projectId=PROJECT_1"))
    }

    @Test func createdDraftIncludesItsDescription() async throws {
        let runner = FixtureGitHubCommandRunner(responses: [
            #"{"data":{"addProjectV2DraftIssue":{"projectItem":{"id":"DRAFT_1"}}}}"#
        ])
        let service = GitHubService(runner: runner)

        let draftID = try await service.createDraftIssue(
            projectId: "PROJECT_1",
            title: "Plan migration",
            body: "Capture compatibility constraints."
        )
        let calls = await runner.recordedArguments()

        #expect(draftID == "DRAFT_1")
        #expect(calls.count == 1)
        #expect(calls[0].contains { $0.contains("body: $body") })
        #expect(calls[0].contains("body=Capture compatibility constraints."))
        #expect(calls[0].contains("projectId=PROJECT_1"))
        #expect(calls[0].contains("title=Plan migration"))
    }

    @Test func itemDetailDecodesIssuePullRequestAndDraftAuthors() async throws {
        let fixtures: [(response: String, expected: ProjectItemDetail)] = [
            (
                #"{"data":{"node":{"__typename":"Issue","id":"ISSUE1","bodyHTML":"<p>Issue body</p>","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-02T00:00:00Z","author":{"login":"octocat","avatarUrl":"https://example.invalid/octocat"},"viewerCanUpdate":true,"viewerCanSetMilestone":true,"repository":{"nameWithOwner":"acme/app"},"milestone":{"id":"M1","number":2,"title":"Version 2","dueOn":"2026-09-01T00:00:00Z","state":"OPEN","progressPercentage":50},"parent":{"id":"P1","number":10,"title":"Release 2","url":"https://github.com/acme/planning/issues/10","state":"OPEN","repository":{"nameWithOwner":"acme/planning"}},"subIssues":{"nodes":[{"id":"S1","number":11,"title":"Ship API","url":"https://github.com/acme/api/issues/11","state":"CLOSED","repository":{"nameWithOwner":"acme/api"}}]},"subIssuesSummary":{"completed":1,"total":1},"blockedBy":{"nodes":[{"id":"B1","number":12,"title":"Approve schema","url":"https://github.com/acme/schema/issues/12","state":"OPEN","repository":{"nameWithOwner":"acme/schema"}}]},"blocking":{"nodes":[]}}}}"#,
                ProjectItemDetail(
                    id: "ISSUE1",
                    bodyHTML: "<p>Issue body</p>",
                    author: ItemAuthor(
                        login: "octocat",
                        avatarURL: "https://example.invalid/octocat"
                    ),
                    createdAt: "2026-08-01T00:00:00Z",
                    updatedAt: "2026-08-02T00:00:00Z",
                    issueMetadata: IssueMetadata(
                        repository: "acme/app",
                        milestone: RepositoryMilestone(
                            id: "M1",
                            number: 2,
                            title: "Version 2",
                            dueOn: "2026-09-01T00:00:00Z",
                            state: .open,
                            progressPercentage: 50
                        ),
                        parent: IssueReference(
                            id: "P1",
                            repository: "acme/planning",
                            number: 10,
                            title: "Release 2",
                            url: URL(string: "https://github.com/acme/planning/issues/10")!,
                            state: .open
                        ),
                        subIssues: [
                            IssueReference(
                                id: "S1",
                                repository: "acme/api",
                                number: 11,
                                title: "Ship API",
                                url: URL(string: "https://github.com/acme/api/issues/11")!,
                                state: .closed
                            )
                        ],
                        subIssueProgress: SubIssueProgress(completed: 1, total: 1),
                        blockedBy: [
                            IssueReference(
                                id: "B1",
                                repository: "acme/schema",
                                number: 12,
                                title: "Approve schema",
                                url: URL(string: "https://github.com/acme/schema/issues/12")!,
                                state: .open
                            )
                        ],
                        blocking: [],
                        viewerCanUpdate: true,
                        viewerCanSetMilestone: true
                    )
                )
            ),
            (
                #"{"data":{"node":{"__typename":"PullRequest","id":"PR1","bodyHTML":"<p>PR body</p>","createdAt":null,"updatedAt":"2026-08-03T00:00:00Z","author":null}}}"#,
                ProjectItemDetail(
                    id: "PR1",
                    bodyHTML: "<p>PR body</p>",
                    author: nil,
                    createdAt: nil,
                    updatedAt: "2026-08-03T00:00:00Z",
                    issueMetadata: nil
                )
            ),
            (
                #"{"data":{"node":{"__typename":"DraftIssue","id":"DRAFT1","bodyHTML":"","createdAt":"2026-08-04T00:00:00Z","updatedAt":null,"creator":{"login":"hubot","avatarUrl":null}}}}"#,
                ProjectItemDetail(
                    id: "DRAFT1",
                    bodyHTML: "",
                    author: ItemAuthor(login: "hubot", avatarURL: nil),
                    createdAt: "2026-08-04T00:00:00Z",
                    updatedAt: nil,
                    issueMetadata: nil
                )
            )
        ]

        for fixture in fixtures {
            let runner = FixtureGitHubCommandRunner(responses: [fixture.response])
            let service = GitHubService(runner: runner)

            let detail = try await service.fetchItemDetail(contentID: fixture.expected.id)

            #expect(detail == fixture.expected)
            #expect(await runner.recordedArguments().first?.contains("id=\(fixture.expected.id)") == true)
        }
    }

    @Test func itemDetailReportsAnUnavailableNode() async {
        let runner = FixtureGitHubCommandRunner(responses: [#"{"data":{"node":null}}"#])
        let service = GitHubService(runner: runner)

        do {
            _ = try await service.fetchItemDetail(contentID: "MISSING")
            Issue.record("Expected a missing node to be unavailable.")
        } catch let error as GitHubError {
            #expect(error == .itemUnavailable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func repositoryMilestonesFollowPagination() async throws {
        let runner = FixtureGitHubCommandRunner(responses: [
            #"{"data":{"repository":{"milestones":{"nodes":[{"id":"M1","number":1,"title":"Version 1","dueOn":"2026-09-01T00:00:00Z","state":"OPEN","progressPercentage":25}],"pageInfo":{"hasNextPage":true,"endCursor":"next"}}}}}"#,
            #"{"data":{"repository":{"milestones":{"nodes":[{"id":"M2","number":2,"title":"Version 2","dueOn":null,"state":"OPEN","progressPercentage":0}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#
        ])
        let service = GitHubService(runner: runner)

        let milestones = try await service.fetchRepositoryMilestones(repository: "acme/app")
        let calls = await runner.recordedArguments()

        #expect(milestones.map(\.id) == ["M1", "M2"])
        #expect(milestones.map(\.title) == ["Version 1", "Version 2"])
        #expect(calls.count == 2)
        #expect(calls[0].contains("owner=acme"))
        #expect(calls[0].contains("name=app"))
        #expect(calls[1].contains("after=next"))
    }

    @Test func issueMilestoneMutationUsesNodeIDsAndExplicitClear() async throws {
        let runner = FixtureGitHubCommandRunner(responses: [
            #"{"data":{"updateIssue":{"issue":{"id":"I1"}}}}"#,
            #"{"data":{"updateIssue":{"issue":{"id":"I1"}}}}"#
        ])
        let service = GitHubService(runner: runner)

        try await service.updateIssueMilestone(issueID: "I1", milestoneID: "M1")
        try await service.updateIssueMilestone(issueID: "I1", milestoneID: nil)
        let calls = await runner.recordedArguments()

        #expect(calls.count == 2)
        #expect(calls[0].contains("issueId=I1"))
        #expect(calls[0].contains("milestoneId=M1"))
        #expect(calls[1].contains("issueId=I1"))
        #expect(calls[1].contains { $0.contains("milestoneId: null") })
        #expect(calls[1].contains { $0.hasPrefix("milestoneId=") } == false)
    }

}

struct IssueRelationKindTests {
    @Test func relationDirectionsMatchGitHubMutationSemantics() {
        let issueID = "CURRENT"
        let relatedID = "RELATED"

        #expect(
            IssueRelationKind.parent.endpoints(issueID: issueID, relatedIssueID: relatedID)
                == IssueRelationEndpoints(issueID: relatedID, relatedIssueID: issueID)
        )
        #expect(
            IssueRelationKind.subIssue.endpoints(issueID: issueID, relatedIssueID: relatedID)
                == IssueRelationEndpoints(issueID: issueID, relatedIssueID: relatedID)
        )
        #expect(
            IssueRelationKind.blockedBy.endpoints(issueID: issueID, relatedIssueID: relatedID)
                == IssueRelationEndpoints(issueID: issueID, relatedIssueID: relatedID)
        )
        #expect(
            IssueRelationKind.blocking.endpoints(issueID: issueID, relatedIssueID: relatedID)
                == IssueRelationEndpoints(issueID: relatedID, relatedIssueID: issueID)
        )
    }
}

struct QuickCreateParserTests {
    @Test func parsesTriageQualifiersWithoutIncludingThemInTheTitle() {
        let request = QuickCreateParser.parse(
            "> Repair login flow repo:acme/app status:Todo priority:High @me @octocat #bug"
        )

        #expect(request.title == "Repair login flow")
        #expect(request.repository == "acme/app")
        #expect(request.status == "Todo")
        #expect(request.priority == "High")
        #expect(request.assignees == ["me", "octocat"])
        #expect(request.labels == ["bug"])
    }
}

struct ProjectCacheTests {
    @Test func roundTripPreservesTheDomainSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitStrideTests-\(UUID().uuidString)", isDirectory: true)
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
                detailedProjectIDs: ["P1"],
                selectedProjectId: "P1",
                selectedStatusFilter: "Todo"
            )
        )
        let loaded = try #require(try await cache.load())

        #expect(loaded.version == ProjectCacheSnapshot.currentVersion)
        #expect(loaded.accountLogin == "octocat")
        #expect(loaded.detailedProjectIDs == ["P1"])
        #expect(loaded.projects.first?.items.first?.title == "Cached issue")
        #expect(loaded.projects.first?.items.first?.fieldValues["F1"] == .singleSelect(optionId: "HIGH", name: "High"))
    }
}

@MainActor
struct ProjectStoreTests {
    @Test func kanbanDefaultsToTheActiveWorkflowStatusesInProjectOrder() {
        let runner = FixtureGitHubCommandRunner(responses: [])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        let project = Self.kanbanProject()

        #expect(store.visibleKanbanStatuses(in: project).map(\.name) == [
            "Backlog",
            "Todo",
            "In Progress",
            "In Review"
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

    @Test func itemRejectsASecondStatusMoveWhileOneIsPending() async throws {
        let runner = SuspendingGitHubCommandRunner(steps:
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

    @Test func archiveKeepsAnotherItemsCompletedStatusMove() async throws {
        let runner = SuspendingGitHubCommandRunner(steps: try Self.twoItemResponses().map { .response($0) } + [
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

    @Test func createdIssueFinishesInOriginalProjectAndRetryDoesNotRecreateIt() async throws {
        let fields = Self.mutationProjectResponses[3]
        let items = Self.mutationProjectResponses[4]
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
        let creation = Task {
            try await store.createIssueAndAdd(repository: "acme/app", title: "New", body: "",
                                              labels: [], assignees: [], status: "Review")
        }
        await runner.waitUntilSuspended("create")
        store.selectedProjectId = "P2"
        await runner.release("create")
        do {
            try await creation.value
            Issue.record("Expected field failure with a resumable issue")
        } catch let pending as PendingCreatedIssue {
            #expect(pending.projectID == "P1")
            try await store.finishCreatedIssue(pending)
        }
        let calls = await runner.recordedArguments()
        #expect(calls.filter { $0.starts(with: ["issue", "create"]) }.count == 1)
        #expect(calls.filter { $0.contains("optionId=REVIEW") }.count == 2)
        #expect(calls.filter { $0.contains("optionId=REVIEW") }.allSatisfy { $0.contains("projectId=P1") && $0.contains("itemId=ITEM1") })
        #expect(store.selectedProjectId == "P2")
    }

    @Test func contentChangesReachEveryProjectAndKeepProjectStatusIndependent() async throws {
        let fields = Self.mutationProjectResponses[3]
        let items = Self.mutationProjectResponses[4].replacingOccurrences(
            of: "\"labels\":{\"nodes\":[]}",
            with: "\"labels\":{\"nodes\":[{\"id\":\"L1\",\"name\":\"bug\",\"color\":\"ffffff\"}]}"
        )
        let runner = FixtureGitHubCommandRunner(responses: Self.mutationProjectResponses + [
            fields, Self.mutationProjectResponses[4], fields,
            Self.mutationProjectResponses[4].replacingOccurrences(of: "Todo", with: "Review")
                .replacingOccurrences(of: "TODO", with: "REVIEW"),
            "", "", fields, items, fields, items.replacingOccurrences(of: "Todo", with: "Review")
                .replacingOccurrences(of: "TODO", with: "REVIEW")
        ])
        let (store, cleanup) = makeStore(runner: runner)
        defer { cleanup() }
        await store.loadProjects()
        let first = try #require(store.project(id: "P1"))
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
        encoded["id"] = "P2"
        var second = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: encoded))
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

    @Test func staleRefreshCannotRestoreADeletedItemAndCoalescesReconciliation() async throws {
        let fields = Self.mutationProjectResponses[3]
        let runner = SuspendingGitHubCommandRunner(steps: Self.mutationProjectResponses.map { .response($0) } + [
            .suspended("old-read", fields), .response(Self.graphQLSuccessResponse),
            .response(Self.mutationProjectResponses[4]),
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
            .suspended("new-read", Self.mutationProjectResponses[3]), .response(Self.emptyItemsResponse)
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

    @Test func contentMutationInvalidatesAProjectWhoseMembershipWasNotLoadedYet() async throws {
        let fields = Self.mutationProjectResponses[3]
        let updatedItems = Self.mutationProjectResponses[4].replacingOccurrences(
            of: "\"assignees\":{\"nodes\":[]}",
            with: "\"assignees\":{\"nodes\":[{\"login\":\"octocat\",\"avatarUrl\":\"\",\"name\":null}]}"
        )
        let runner = SuspendingGitHubCommandRunner(steps: Self.mutationProjectResponses.map { .response($0) } + [
            .suspended("new-project", fields), .response(""),
            .response(Self.mutationProjectResponses[4]),
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
        let runner = SuspendingGitHubCommandRunner(steps: Self.mutationProjectResponses.map { .response($0) } + [
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
        let store = ProjectStore(gitHubService: GitHubService(runner: runner), projectCache: cache, defaults: defaults)
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
        let fields = Self.mutationProjectResponses[3]
        let runner = SuspendingGitHubCommandRunner(steps: Self.mutationProjectResponses.map { .response($0) } + [
            .suspended("old-membership", fields), .suspended("new-membership", fields),
            .response(Self.mutationProjectResponses[4]), .response(Self.emptyItemsResponse)
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

    @Test func contentMutationInvalidatesAnInFlightDetailRead() async throws {
        let runner = SuspendingGitHubCommandRunner(steps: Self.mutationProjectResponses.map { .response($0) } + [
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

    private static func twoItemResponses() throws -> [String] {
        var responses = mutationProjectResponses
        var body = try #require(JSONSerialization.jsonObject(with: Data(responses[4].utf8)) as? [String: Any])
        var data = try #require(body["data"] as? [String: Any])
        var node = try #require(data["node"] as? [String: Any])
        var items = try #require(node["items"] as? [String: Any])
        var nodes = try #require(items["nodes"] as? [[String: Any]])
        var second = nodes[0]
        second["id"] = "ITEM2"
        nodes.append(second)
        items["nodes"] = nodes
        node["items"] = items
        data["node"] = node
        body["data"] = data
        responses[4] = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        return responses
    }

    private func makeStore(
        runner: any GitHubCommandRunning
    ) -> (ProjectStore, @MainActor () -> Void) {
        let identifier = "GitStrideTests.ProjectStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: identifier)!
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(identifier).json")
        let store = ProjectStore(
            gitHubService: GitHubService(runner: runner),
            projectCache: ProjectCache(fileURL: cacheURL),
            defaults: defaults
        )
        return (store, {
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: cacheURL)
        })
    }

    private static let sessionResponse =
        #"{"data":{"viewer":{"id":"U1","login":"me"}}}"#

    private static let ownersResponse =
        #"{"data":{"viewer":{"id":"U1","login":"me","name":null,"organizations":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#

    private static let projectsResponse =
        #"{"data":{"owner":{"projectsV2":{"nodes":[{"id":"P1","title":"One","number":1,"url":"https://github.com/users/me/projects/1","viewerCanUpdate":true},{"id":"P2","title":"Two","number":2,"url":"https://github.com/users/me/projects/2","viewerCanUpdate":true}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#

    private static let firstProjectFieldsResponse =
        #"{"data":{"node":{"title":"One","number":1,"url":"https://github.com/users/me/projects/1","viewerCanUpdate":true,"fields":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#

    private static let secondProjectFieldsResponse =
        #"{"data":{"node":{"title":"Two","number":2,"url":"https://github.com/users/me/projects/2","viewerCanUpdate":true,"fields":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#

    private static let emptyItemsResponse =
        #"{"data":{"node":{"items":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#

    private static let emptyProjectResponses = [
        sessionResponse,
        ownersResponse,
        #"{"data":{"owner":{"projectsV2":{"nodes":[{"id":"P1","title":"One","number":1,"url":"https://github.com/users/me/projects/1","viewerCanUpdate":true}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#,
        firstProjectFieldsResponse,
        emptyItemsResponse
    ]

    private static let mutationProjectResponses = [
        sessionResponse,
        ownersResponse,
        #"{"data":{"owner":{"projectsV2":{"nodes":[{"id":"P1","title":"One","number":1,"url":"https://github.com/users/me/projects/1","viewerCanUpdate":true}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#,
        #"{"data":{"node":{"title":"One","number":1,"url":"https://github.com/users/me/projects/1","viewerCanUpdate":true,"fields":{"nodes":[{"__typename":"ProjectV2SingleSelectField","id":"STATUS","name":"Status","dataType":"SINGLE_SELECT","options":[{"id":"TODO","name":"Todo","color":"GRAY"},{"id":"REVIEW","name":"Review","color":"YELLOW"}]}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#,
        #"{"data":{"node":{"items":{"nodes":[{"id":"ITEM1","content":{"__typename":"Issue","id":"CONTENT1","title":"Item","number":1,"url":"https://github.com/acme/app/issues/1","state":"OPEN","updatedAt":"2026-08-01T00:00:00Z","assignees":{"nodes":[]},"labels":{"nodes":[]},"closedByPullRequestsReferences":{"nodes":[]}},"fieldValueByName":{"name":"Todo","optionId":"TODO"},"fieldValues":{"nodes":[{"__typename":"ProjectV2ItemFieldSingleSelectValue","name":"Todo","optionId":"TODO","field":{"id":"STATUS"}}]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#
    ]

    private static let graphQLFailureResponse =
        #"{"data":null,"errors":[{"message":"Status failed"}]}"#

    private static let graphQLSuccessResponse =
        #"{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"P1"}}}}"#

    private static func kanbanProject() -> Project {
        let statuses = [
            ("DONE", "Done"),
            ("BACKLOG", "Backlog"),
            ("TODO", "Todo"),
            ("IN_PROGRESS", "In Progress"),
            ("IN_REVIEW", "In Review"),
            ("CANCELED", "Canceled")
        ].map { id, name in
            StatusOption(id: id, name: name, color: "GRAY")
        }
        return Project(
            id: "KANBAN_PROJECT",
            owner: ProjectOwner(id: "OWNER", login: "owner", name: nil, kind: .user),
            title: "Kanban",
            number: 1,
            url: "https://github.com/users/owner/projects/1",
            viewerCanUpdate: true,
            statusField: StatusField(id: "STATUS", name: "Status", options: statuses)
        )
    }

    private static func detailItem(updatedAt: String) -> ProjectItem {
        ProjectItem(
            id: "ITEM1",
            contentId: "CONTENT1",
            contentType: .issue,
            title: "Detail item",
            number: 1,
            url: "https://github.com/acme/app/issues/1",
            issueState: .open,
            prState: nil,
            updatedAt: updatedAt,
            status: nil,
            statusOptionId: nil,
            assignees: []
        )
    }

    private static func itemDetailResponse(body: String) -> String {
        #"{"data":{"node":{"__typename":"Issue","id":"CONTENT1","bodyHTML":"\#(body)","createdAt":null,"updatedAt":"2026-08-01T00:00:00Z","author":null,"viewerCanUpdate":false,"viewerCanSetMilestone":false,"repository":{"nameWithOwner":"acme/repo"},"milestone":null,"parent":null,"subIssues":{"nodes":[]},"subIssuesSummary":{"completed":0,"total":0},"blockedBy":{"nodes":[]},"blocking":{"nodes":[]}}}}"#
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

    @Test func engineeringViewsUseReviewAndMergeSignals() {
        let owner = ProjectOwner(id: "U1", login: "octocat", name: nil, kind: .user)
        let item = ProjectItem(
            id: "ITEM",
            contentId: "PR",
            contentType: .pullRequest,
            title: "Ready change",
            number: 9,
            url: "https://github.com/acme/app/pull/9",
            issueState: nil,
            prState: .open,
            status: "Review",
            statusOptionId: "REVIEW",
            assignees: [],
            engineeringSignals: EngineeringSignals(
                mergeability: .mergeable,
                reviewDecision: .approved,
                checkStatus: .success,
                reviewRequestedLogins: ["octocat"]
            )
        )
        let project = Project(
            id: "P1",
            owner: owner,
            title: "Work",
            number: 1,
            url: "https://github.com/users/octocat/projects/1",
            viewerCanUpdate: true,
            items: [item]
        )
        let workItem = MyWorkItem(project: project, item: item)

        #expect(MyWorkFilter.reviewRequested.includes(workItem, currentUserLogin: "octocat"))
        #expect(MyWorkFilter.readyToMerge.includes(workItem, currentUserLogin: "octocat"))
        #expect(MyWorkFilter.ciFailed.includes(workItem, currentUserLogin: "octocat") == false)
    }
}

struct ProjectChangeDetectorTests {
    @Test func reportsOnlyMeaningfulTransitionsForExistingItems() {
        let owner = ProjectOwner(id: "U1", login: "octocat", name: nil, kind: .user)
        let item = ProjectItem(
            id: "I1",
            contentId: "C1",
            contentType: .issue,
            title: "Ship release",
            number: 12,
            url: "https://github.com/acme/app/issues/12",
            issueState: .open,
            prState: nil,
            status: "Done",
            statusOptionId: "DONE",
            assignees: [],
            labels: []
        )
        let project = Project(
            id: "P1",
            owner: owner,
            title: "Roadmap",
            number: 1,
            url: "https://github.com/users/octocat/projects/1",
            viewerCanUpdate: true,
            statusField: StatusField(
                id: "STATUS",
                name: "Status",
                options: [StatusOption(id: "DONE", name: "Done", color: "GREEN")]
            ),
            items: [item]
        )
        let previous = [
            "P1:I1": MonitoredItemState(
                projectID: "P1",
                itemID: "I1",
                status: "In progress",
                assignedToCurrentUser: false,
                dueState: .none,
                isBlocked: false
            )
        ]
        let current = [
            "P1:I1": MonitoredItemState(
                projectID: "P1",
                itemID: "I1",
                status: "Done",
                assignedToCurrentUser: true,
                dueState: .overdue,
                isBlocked: true,
                reviewRequested: true,
                checkStatus: .failure
            ),
            "P1:NEW": MonitoredItemState(
                projectID: "P1",
                itemID: "NEW",
                status: "Todo",
                assignedToCurrentUser: true,
                dueState: .none,
                isBlocked: false
            )
        ]

        let changes = ProjectChangeDetector.changes(
            from: previous,
            to: current,
            projects: [project]
        )

        #expect(changes.map(\.kind) == [
            .status(from: "In progress", to: "Done"),
            .assignedToMe,
            .overdue,
            .blocked,
            .reviewRequested,
            .ciFailed
        ])
        #expect(changes.allSatisfy { $0.itemID == "I1" })
        #expect(changes.allSatisfy { $0.statusFieldID == "STATUS" })
        #expect(changes.allSatisfy { $0.doneOptionID == "DONE" })
    }

    @Test func quietHoursCanCrossMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let policy = MonitoringPolicy(interval: .seconds(900), quietStartHour: 22, quietEndHour: 8)
        let late = try Date("2026-08-27T23:00:00Z", strategy: .iso8601)
        let morning = try Date("2026-08-27T07:00:00Z", strategy: .iso8601)
        let noon = try Date("2026-08-27T12:00:00Z", strategy: .iso8601)

        #expect(policy.isQuiet(at: late, calendar: calendar))
        #expect(policy.isQuiet(at: morning, calendar: calendar))
        #expect(policy.isQuiet(at: noon, calendar: calendar) == false)
    }
}

private actor FixtureGitHubCommandRunner: GitHubCommandRunning {
    private var responses: [Data]
    private var calls: [[String]] = []
    private var inputs: [Data?] = []

    init(responses: [String]) {
        self.responses = responses.map { Data($0.utf8) }
    }

    func run(arguments: [String], standardInput: Data?) async throws -> GitHubCommandResult {
        calls.append(arguments)
        inputs.append(standardInput)
        guard responses.isEmpty == false else {
            throw FixtureError.missingResponse
        }
        return GitHubCommandResult(
            standardOutput: responses.removeFirst(),
            standardError: Data()
        )
    }

    func recordedInputs() -> [Data?] { inputs }

    func recordedArguments() -> [[String]] {
        calls
    }

    private enum FixtureError: Error {
        case missingResponse
    }
}

private enum SuspendingRunnerStep: Sendable {
    case response(String)
    case suspended(String, String)
}

private actor SuspendingGitHubCommandRunner: GitHubCommandRunning {
    private var steps: [SuspendingRunnerStep]
    private var callCount = 0
    private var calls: [[String]] = []
    private var suspendedIDs: Set<String> = []
    private var resultWaiters: [String: CheckedContinuation<GitHubCommandResult, Never>] = [:]
    private var suspensionWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(steps: [SuspendingRunnerStep]) {
        self.steps = steps
    }

    func run(arguments: [String], standardInput: Data?) async throws -> GitHubCommandResult {
        guard steps.isEmpty == false else { throw RunnerError.missingResponse }
        callCount += 1
        calls.append(arguments)

        switch steps.removeFirst() {
        case .response(let response):
            return result(response)
        case .suspended(let id, let response):
            suspendedIDs.insert(id)
            suspensionWaiters.removeValue(forKey: id)?.forEach { $0.resume() }
            return await withCheckedContinuation { continuation in
                resultWaiters[id] = continuation
                suspendedResponses[id] = response
            }
        }
    }

    func waitUntilSuspended(_ id: String) async {
        guard suspendedIDs.contains(id) == false else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters[id, default: []].append(continuation)
        }
    }

    func release(_ id: String) {
        guard let continuation = resultWaiters.removeValue(forKey: id),
              let response = suspendedResponses.removeValue(forKey: id) else { return }
        continuation.resume(returning: result(response))
    }

    func recordedArguments() -> [[String]] { calls }

    func recordedCallCount() -> Int {
        callCount
    }

    private var suspendedResponses: [String: String] = [:]

    private func result(_ response: String) -> GitHubCommandResult {
        GitHubCommandResult(standardOutput: Data(response.utf8), standardError: Data())
    }

    private enum RunnerError: Error {
        case missingResponse
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
