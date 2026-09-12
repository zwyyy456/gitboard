import Foundation
import Testing
@testable import GitStride

struct GitHubServiceTests {
    @Test(arguments: ["Issue", "PullRequest"])
    func previewsItemURLWithoutAddingIt(_ typename: String) async throws {
        let path = typename == "Issue" ? "issues" : "pull"
        let url = "https://github.com/octocat/example/\(path)/42"
        let runner = FixtureGitHubCommandRunner(responses: [
            """
            {"data":{"resource":{"__typename":"\(typename)","id":"ITEM","title":"Example item","number":42,"url":"\(url)","repository":{"nameWithOwner":"octocat/example"}}}}
            """
        ])
        let item = try await GitHubService(runner: runner).resolveItem(url: url)
        #expect(item.id == "ITEM")
        #expect(item.contentType == (typename == "Issue" ? .issue : .pullRequest))
        #expect(item.repository == "octocat/example")
        #expect(item.title == "Example item")
        #expect(item.number == 42)
        #expect(item.url == url)
        let calls = await runner.recordedArguments()
        #expect(calls.count == 1)
        #expect(calls[0].contains("query=\(GraphQLQueries.itemAtURL)"))
        #expect(calls[0].contains("url=\(url)"))
    }

    @Test func itemURLPreviewReportsMissingItem() async throws {
        let runner = FixtureGitHubCommandRunner(responses: [#"{"data":{"resource":null}}"#])
        await #expect(throws: GitHubError.graphQLError("Item not found or no longer accessible.")) {
            try await GitHubService(runner: runner).resolveItem(url: "https://github.com/octocat/example/issues/42")
        }
    }

    @Test func itemURLPreviewRejectsNonItemURLBeforeRequesting() async throws {
        let runner = FixtureGitHubCommandRunner(responses: [])
        await #expect(throws: GitHubError.invalidItemURL) {
            try await GitHubService(runner: runner).resolveItem(url: "https://github.com/octocat/example")
        }
        #expect(await runner.recordedArguments().isEmpty)
    }

    private static let createdProjectResponse = """
        {"data":{"createProjectV2":{"projectV2":{"id":"NEW","title":"New project","number":9,"url":"https://github.com/users/me/projects/9","viewerCanUpdate":true}}}}
        """

    @Test(arguments: [(ProjectOwnerKind.user, nil as String?), (.organization, "REPO")])
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
            {"data":{"node":{"title":"Work","number":7,"url":"https://github.com/users/me/projects/7","viewerCanUpdate":true,"repositories":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}},"fields":{"nodes":[{"__typename":"ProjectV2SingleSelectField","id":"F1","name":"Status","dataType":"SINGLE_SELECT","options":[{"id":"todo","name":"Todo","color":"GRAY"}]},{"__typename":"ProjectV2IterationField","id":"F2","name":"Iteration","dataType":"ITERATION","configuration":{"iterations":[{"id":"SPRINT1","title":"Sprint 1","startDate":"2026-08-24","duration":14}],"completedIterations":[]}},{"__typename":"ProjectV2Field","id":"F3","name":"Estimate","dataType":"NUMBER"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}
            """,
            """
            {"data":{"node":{"items":{"nodes":[{"id":"I1","content":{"__typename":"Issue","id":"CONTENT1","title":"First","number":1,"url":"https://github.com/acme/repo/issues/1","state":"OPEN","assignees":{"nodes":[]},"labels":{"nodes":[{"id":"L1","name":"bug","color":"d73a4a"}]},"closedByPullRequestsReferences":{"nodes":[]},"subIssuesSummary":{"completed":2,"total":3},"issueDependenciesSummary":{"blockedBy":1,"blocking":4},"milestone":{"id":"M1","title":"v1"},"parent":{"id":"P1","title":"Delivery","number":9,"repository":{"nameWithOwner":"acme/plan"}},"issueType":{"id":"T1","name":"Bug"}},"fieldValueByName":{"name":"Todo","optionId":"todo"},"fieldValues":{"nodes":[{"__typename":"ProjectV2ItemFieldSingleSelectValue","name":"Todo","optionId":"todo","field":{"id":"F1"}},{"__typename":"ProjectV2ItemFieldIterationValue","title":"Sprint 1","iterationId":"SPRINT1","field":{"id":"F2"}},{"__typename":"ProjectV2ItemFieldNumberValue","number":3,"field":{"id":"F3"}},{"__typename":"ProjectV2ItemFieldRepositoryValue"}]}}],"pageInfo":{"hasNextPage":true,"endCursor":"items-next"}}}}}
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
        #expect(project.items[0].milestone?.id == "M1")
        #expect(project.items[0].milestone?.repository == "acme/repo")
        #expect(project.items[0].parentIssue?.repository == "acme/plan")
        #expect(project.items[0].issueType?.name == "Bug")
        #expect(project.items[0].fieldValues["F2"] == .iteration(id: "SPRINT1", title: "Sprint 1"))
        #expect(project.items[0].fieldValues["F3"] == .number(3))
        #expect(project.items[1].signals.isReadyToMerge)
        #expect(project.items[1].signals.reviewRequested(for: "octocat"))
        #expect(project.items[2].contentType == .redacted)
        #expect(calls[2].contains("after=items-next"))
    }

    @Test func projectItemQueryRequestsTypeForEveryFieldValue() {
        let selectionPattern = #"fieldValues\([^)]*\)\s*\{\s*nodes\s*\{[^{}]*\b__typename\b"#

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

    @Test func creationAndProjectMembershipUseSeparateCommands() async throws {
        let runner = FixtureGitHubCommandRunner(responses: [
            #"{"data":{"repository":{"id":"REPO1","labels":{"nodes":[{"id":"BUG","name":"bug"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#,
            #"{"data":{"user":{"id":"USER1"}}}"#,
            #"{"data":{"createIssue":{"issue":{"id":"ISSUE_NODE_42","url":"https://github.com/acme/widgets/issues/42"}}}}"#,
            "ISSUE_NODE_42\n",
            """
            {"data":{"addProjectV2ItemById":{"item":{"id":"PROJECT_ITEM_42"}}}}
            """
        ])
        let service = GitHubService(runner: runner)

        let issueURL = try await service.createIssue(
            repository: "acme/widgets",
            title: "Repair login",
            body: "Login fails after token refresh.",
            labels: ["bug"],
            assignees: ["octocat"]
        )
        let itemID = try await service.addExistingItem(projectId: "PROJECT_1", url: issueURL)
        let calls = await runner.recordedArguments()
        let input = try #require(await runner.recordedInputs()[2])
        let request = try #require(JSONSerialization.jsonObject(with: input) as? [String: Any])
        let variables = try #require(request["variables"] as? [String: Any])

        #expect(issueURL == "https://github.com/acme/widgets/issues/42")
        #expect(itemID == "PROJECT_ITEM_42")
        #expect(calls.count == 5)
        #expect(calls[0].contains("owner=acme") && calls[0].contains("name=widgets"))
        #expect(variables["repositoryId"] as? String == "REPO1")
        #expect(variables["title"] as? String == "Repair login")
        #expect(variables["body"] as? String == "Login fails after token refresh.")
        #expect(variables["labelIds"] as? [String] == ["BUG"])
        #expect(variables["assigneeIds"] as? [String] == ["USER1"])
        #expect(calls[3].contains("repos/acme/widgets/issues/42"))
        #expect(calls[4].contains("contentId=ISSUE_NODE_42"))
        #expect(calls[4].contains("projectId=PROJECT_1"))
    }

    @Test func issueCreationReusesLabelsAcrossPagesAndCreatesOnlyMissingNames() async throws {
        let runner = FixtureGitHubCommandRunner(responses: [
            #"{"data":{"repository":{"id":"REPO1","labels":{"nodes":[{"id":"BUG","name":"Bug"}],"pageInfo":{"hasNextPage":true,"endCursor":"labels-next"}}}}}"#,
            #"{"data":{"repository":{"id":"REPO1","labels":{"nodes":[{"id":"DOCS","name":"docs"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#,
            #"{"data":{"createLabel":{"label":{"id":"FEATURE","name":"feature"}}}}"#,
            #"{"data":{"createIssue":{"issue":{"id":"ISSUE1","url":"https://github.com/acme/app/issues/1"}}}}"#
        ])
        _ = try await GitHubService(runner: runner).createIssue(
            repository: "acme/app", title: "New", body: "",
            labels: ["bug", "feature", "FEATURE", "docs"]
        )
        let calls = await runner.recordedArguments()
        #expect(calls.count == 4)
        #expect(calls[1].contains("after=labels-next"))
        #expect(calls[2].contains("name=feature"))
        #expect(calls[2].contains("repositoryId=REPO1"))
        let input = try #require(await runner.recordedInputs()[3])
        let request = try #require(JSONSerialization.jsonObject(with: input) as? [String: Any])
        let variables = try #require(request["variables"] as? [String: Any])
        #expect(variables["labelIds"] as? [String] == ["BUG", "FEATURE", "DOCS"])
    }

    @Test func projectRepositoriesPaginateIndependentlyOfFields() async throws {
        let first = #"{"data":{"node":{"title":"Work","number":1,"url":"https://github.com/users/me/projects/1","viewerCanUpdate":true,"repositories":{"nodes":[{"nameWithOwner":"acme/one"}],"pageInfo":{"hasNextPage":true,"endCursor":"repos-next"}},"fields":{"nodes":[{"id":"TEXT","name":"Notes","dataType":"TEXT"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#
        let second = first.replacingOccurrences(of: "acme/one", with: "acme/two")
            .replacingOccurrences(of: #""hasNextPage":true,"endCursor":"repos-next""#,
                                  with: #""hasNextPage":false,"endCursor":null"#)
        let runner = FixtureGitHubCommandRunner(responses: [
            first, second, #"{"data":{"node":{"items":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#
        ])
        let owner = ProjectOwner(id: "OWNER", login: "me", name: nil, kind: .user)
        let project = try await GitHubService(runner: runner).fetchProjectWithItems(id: "P1", owner: owner)
        #expect(project.linkedRepositories == ["acme/one", "acme/two"])
        #expect(project.fields.map(\.id) == ["TEXT"])
        #expect(await runner.recordedArguments()[1].contains("repositoryAfter=repos-next"))
    }

    @Test func projectMembershipRequiresReturnedItemIdentity() async throws {
        let runner = FixtureGitHubCommandRunner(responses: [
            "ISSUE_NODE_42",
            #"{"data":{"addProjectV2ItemById":{"item":{}}}}"#
        ])
        let service = GitHubService(runner: runner)

        do {
            _ = try await service.addExistingItem(
                projectId: "PROJECT_1", url: "https://github.com/acme/widgets/issues/42"
            )
            Issue.record("Expected missing project item identity to be rejected")
        } catch {
            guard case GitHubError.decodingError = error else { throw error }
        }
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
