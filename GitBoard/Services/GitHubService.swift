import Foundation

enum GitHubError: Error, LocalizedError, Equatable {
    case ghCLINotFound
    case notAuthenticated
    case missingProjectScope
    case organizationAccess(String)
    case rateLimited(String?)
    case invalidRepository
    case invalidItemURL
    case itemUnavailable
    case issueCreatedButNotAdded(String?)
    case graphQLError(String)
    case decodingError(String)
    case processError(String)

    var errorDescription: String? {
        switch self {
        case .ghCLINotFound:
            return "GitHub CLI (gh) not found. Please install it from https://cli.github.com"
        case .notAuthenticated:
            return "Not authenticated with GitHub. Run 'gh auth login' in Terminal."
        case .missingProjectScope:
            return "GitBoard needs the GitHub project scope. Run 'gh auth refresh -s project' in Terminal."
        case .organizationAccess(let message):
            return message
        case .rateLimited(let resetDescription):
            if let resetDescription {
                return "GitHub rate limit reached. Try again \(resetDescription)."
            }
            return "GitHub rate limit reached. Try again later."
        case .invalidRepository:
            return "Enter a repository as owner/name."
        case .invalidItemURL:
            return "Enter a GitHub issue or pull request URL."
        case .itemUnavailable:
            return "This item is unavailable or no longer accessible."
        case .issueCreatedButNotAdded(let url):
            if let url {
                return "The issue was created at \(url), but GitHub could not add it to this project. You can paste the URL into Add Existing to retry."
            }
            return "The issue was created, but GitHub did not return its URL, so GitBoard could not add it to this project."
        case .graphQLError(let message):
            return "GitHub API error: \(message)"
        case .decodingError(let message):
            return "Failed to parse GitHub response: \(message)"
        case .processError(let message):
            return "GitHub CLI error: \(message)"
        }
    }
}

struct GitHubAccount: Equatable, Sendable {
    let id: String
    let login: String
}

enum GitHubSessionState: Equatable, Sendable {
    case checking
    case missingCLI
    case signedOut
    case missingProjectScope
    case ready(GitHubAccount)
    case failed(String)
}

actor GitHubService {
    static let shared = GitHubService()

    private let runner: any GitHubCommandRunning
    private let decoder = JSONDecoder()

    init(runner: any GitHubCommandRunning = ProcessGitHubCommandRunner()) {
        self.runner = runner
    }

    func inspectSession() async -> GitHubSessionState {
        do {
            let payload: SessionPayload = try await request(
                GraphQLQueries.sessionProbe,
                as: SessionPayload.self
            )
            return .ready(GitHubAccount(id: payload.viewer.id, login: payload.viewer.login))
        } catch GitHubError.ghCLINotFound {
            return .missingCLI
        } catch GitHubError.notAuthenticated {
            return .signedOut
        } catch GitHubError.missingProjectScope {
            return .missingProjectScope
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func fetchOwners() async throws -> [ProjectOwner] {
        var after: String?
        var userOwner: ProjectOwner?
        var organizations: [ProjectOwner] = []

        repeat {
            try Task.checkCancellation()
            let payload: OwnersPayload = try await request(
                GraphQLQueries.owners,
                variables: cursorVariables(after),
                as: OwnersPayload.self
            )

            if userOwner == nil {
                userOwner = ProjectOwner(
                    id: payload.viewer.id,
                    login: payload.viewer.login,
                    name: payload.viewer.name,
                    kind: .user
                )
            }

            organizations.append(contentsOf: payload.viewer.organizations.nodes.map {
                ProjectOwner(
                    id: $0.id,
                    login: $0.login,
                    name: $0.name,
                    kind: .organization
                )
            })
            after = try nextCursor(from: payload.viewer.organizations.pageInfo)
        } while after != nil

        guard let userOwner else {
            throw GitHubError.decodingError("The authenticated GitHub user is missing.")
        }
        return [userOwner] + organizations
    }

    func fetchProjects(owner: ProjectOwner) async throws -> [Project] {
        let query = owner.kind == .user
            ? GraphQLQueries.userProjects
            : GraphQLQueries.organizationProjects
        var after: String?
        var projects: [Project] = []

        repeat {
            try Task.checkCancellation()
            var variables = cursorVariables(after)
            if owner.kind == .organization {
                variables["login"] = owner.login
            }

            let payload: ProjectsPayload = try await request(
                query,
                variables: variables,
                as: ProjectsPayload.self
            )
            guard let remoteOwner = payload.owner else {
                throw GitHubError.organizationAccess(
                    "GitHub did not return projects for \(owner.login). Check organization or SSO access."
                )
            }

            projects.append(contentsOf: remoteOwner.projectsV2.nodes.map {
                Project(
                    id: $0.id,
                    owner: owner,
                    title: $0.title,
                    number: $0.number,
                    url: $0.url,
                    viewerCanUpdate: $0.viewerCanUpdate
                )
            })
            after = try nextCursor(from: remoteOwner.projectsV2.pageInfo)
        } while after != nil

        return projects
    }

    func fetchProjectWithItems(id: String, owner: ProjectOwner) async throws -> Project {
        let projectData = try await fetchProjectFields(projectID: id)
        let itemNodes = try await fetchProjectItemNodes(projectID: id)

        let fields = projectData.fields.compactMap(makeProjectField)

        let statusField = fields.first { $0.name == "Status" && $0.kind == .singleSelect }
            .map { field in
                StatusField(
                    id: field.id,
                    name: field.name,
                    options: field.options.map {
                        StatusOption(id: $0.id, name: $0.name, color: $0.color ?? "GRAY")
                    }
                )
            }

        return Project(
            id: id,
            owner: owner,
            title: projectData.title,
            number: projectData.number,
            url: projectData.url,
            viewerCanUpdate: projectData.viewerCanUpdate,
            fields: fields,
            statusField: statusField,
            items: itemNodes.map(makeProjectItem)
        )
    }

    func fetchItemDetail(contentID: String) async throws -> ProjectItemDetail {
        let payload: ItemDetailPayload = try await request(
            GraphQLQueries.itemDetail,
            variables: ["id": contentID],
            as: ItemDetailPayload.self
        )
        guard let node = payload.node,
              node.typename == "Issue"
                || node.typename == "PullRequest"
                || node.typename == "DraftIssue",
              let id = node.id else {
            throw GitHubError.itemUnavailable
        }

        let author = node.typename == "DraftIssue" ? node.creator : node.author
        let issueMetadata: IssueMetadata?
        if node.typename == "Issue" {
            guard let repository = node.repository?.nameWithOwner else {
                throw GitHubError.decodingError("GitHub returned an issue without a repository.")
            }
            issueMetadata = IssueMetadata(
                repository: repository,
                milestone: node.milestone.flatMap(makeMilestone),
                parent: node.parent.flatMap(makeIssueReference),
                subIssues: node.subIssues?.nodes.compactMap(makeIssueReference) ?? [],
                subIssueProgress: node.subIssuesSummary.flatMap {
                    $0.total > 0
                        ? SubIssueProgress(completed: $0.completed, total: $0.total)
                        : nil
                },
                blockedBy: node.blockedBy?.nodes.compactMap(makeIssueReference) ?? [],
                blocking: node.blocking?.nodes.compactMap(makeIssueReference) ?? [],
                viewerCanUpdate: node.viewerCanUpdate ?? false,
                viewerCanSetMilestone: node.viewerCanSetMilestone ?? false
            )
        } else {
            issueMetadata = nil
        }

        return ProjectItemDetail(
            id: id,
            bodyHTML: node.bodyHTML ?? "",
            author: author.map { ItemAuthor(login: $0.login, avatarURL: $0.avatarUrl) },
            createdAt: node.createdAt,
            updatedAt: node.updatedAt,
            issueMetadata: issueMetadata
        )
    }

    private func makeIssueReference(_ node: ItemDetailPayload.IssueNode) -> IssueReference? {
        guard let state = IssueState(rawValue: node.state),
              let url = URL(string: node.url) else { return nil }
        return IssueReference(
            id: node.id,
            repository: node.repository.nameWithOwner,
            number: node.number,
            title: node.title,
            url: url,
            state: state
        )
    }

    private func makeMilestone(_ node: ItemDetailPayload.MilestoneNode) -> RepositoryMilestone? {
        guard let state = MilestoneState(rawValue: node.state) else { return nil }
        return RepositoryMilestone(
            id: node.id,
            number: node.number,
            title: node.title,
            dueOn: node.dueOn,
            state: state,
            progressPercentage: node.progressPercentage
        )
    }

    func updateItemStatus(
        projectId: String,
        itemId: String,
        fieldId: String,
        optionId: String
    ) async throws {
        let _: EmptyPayload = try await request(
            GraphQLQueries.updateItemStatus,
            variables: [
                "projectId": projectId,
                "itemId": itemId,
                "fieldId": fieldId,
                "optionId": optionId
            ],
            as: EmptyPayload.self
        )
    }

    func updateItemField(
        projectId: String,
        itemId: String,
        fieldId: String,
        value: ProjectFieldValue?
    ) async throws {
        guard let value else {
            let _: EmptyPayload = try await request(
                GraphQLQueries.clearItemField,
                variables: ["projectId": projectId, "itemId": itemId, "fieldId": fieldId],
                as: EmptyPayload.self
            )
            return
        }

        let variables = ["projectId": projectId, "itemId": itemId, "fieldId": fieldId]
        switch value {
        case .singleSelect(let optionId, _):
            let _: EmptyPayload = try await request(
                GraphQLQueries.updateItemStatus,
                variables: variables.merging(["optionId": optionId]) { _, new in new },
                as: EmptyPayload.self
            )
        case .iteration(let id, _):
            let _: EmptyPayload = try await request(
                GraphQLQueries.updateIterationField,
                variables: variables.merging(["iterationId": id]) { _, new in new },
                as: EmptyPayload.self
            )
        case .date(let date):
            let _: EmptyPayload = try await request(
                GraphQLQueries.updateDateField,
                variables: variables.merging(["date": date]) { _, new in new },
                as: EmptyPayload.self
            )
        case .number(let number):
            let _: EmptyPayload = try await request(
                GraphQLQueries.updateNumberField,
                variables: variables,
                numberVariables: ["number": number],
                as: EmptyPayload.self
            )
        case .text(let text):
            let _: EmptyPayload = try await request(
                GraphQLQueries.updateTextField,
                variables: variables.merging(["text": text]) { _, new in new },
                as: EmptyPayload.self
            )
        }
    }

    func archiveItem(projectId: String, itemId: String) async throws {
        let _: EmptyPayload = try await request(
            GraphQLQueries.archiveItem,
            variables: ["projectId": projectId, "itemId": itemId],
            as: EmptyPayload.self
        )
    }

    func deleteItem(projectId: String, itemId: String) async throws {
        let _: EmptyPayload = try await request(
            GraphQLQueries.deleteItem,
            variables: ["projectId": projectId, "itemId": itemId],
            as: EmptyPayload.self
        )
    }

    func searchUsers(query: String) async throws -> [Assignee] {
        let payload: UserSearchPayload = try await request(
            GraphQLQueries.searchUsers,
            variables: ["query": query],
            as: UserSearchPayload.self
        )
        return payload.search.nodes.compactMap { node in
            guard let login = node.login, let avatarURL = node.avatarUrl else {
                return nil
            }
            return Assignee(login: login, avatarUrl: avatarURL, name: node.name)
        }
    }

    func addAssignee(issueUrl: String, userLogin: String) async throws {
        guard let components = parseIssueURL(issueUrl) else {
            throw GitHubError.graphQLError("Invalid issue URL")
        }
        _ = try await run([
            components.command, "edit", String(components.number),
            "--repo", "\(components.owner)/\(components.repository)",
            "--add-assignee", userLogin
        ])
    }

    func removeAssignee(issueUrl: String, userLogin: String) async throws {
        guard let components = parseIssueURL(issueUrl) else {
            throw GitHubError.graphQLError("Invalid issue URL")
        }
        _ = try await run([
            components.command, "edit", String(components.number),
            "--repo", "\(components.owner)/\(components.repository)",
            "--remove-assignee", userLogin
        ])
    }

    func addLabel(issueUrl: String, label: String) async throws {
        guard let components = parseIssueURL(issueUrl) else {
            throw GitHubError.invalidItemURL
        }
        _ = try await run([
            components.command, "edit", String(components.number),
            "--repo", "\(components.owner)/\(components.repository)",
            "--add-label", label
        ])
    }

    func removeLabel(issueUrl: String, label: String) async throws {
        guard let components = parseIssueURL(issueUrl) else {
            throw GitHubError.invalidItemURL
        }
        _ = try await run([
            components.command, "edit", String(components.number),
            "--repo", "\(components.owner)/\(components.repository)",
            "--remove-label", label
        ])
    }

    func createDraftIssue(projectId: String, title: String) async throws -> String {
        let payload: DraftIssuePayload = try await request(
            GraphQLQueries.addDraftIssue,
            variables: ["projectId": projectId, "title": title],
            as: DraftIssuePayload.self
        )
        return payload.addProjectV2DraftIssue.projectItem.id
    }

    func createIssueAndAdd(
        projectId: String,
        repository: String,
        title: String,
        labels: [String] = [],
        assignees: [String] = []
    ) async throws -> String {
        guard let repository = parseRepository(repository) else {
            throw GitHubError.invalidRepository
        }
        var arguments = [
            "issue", "create",
            "--repo", repository,
            "--title", title,
            "--body", ""
        ]

        if labels.isEmpty == false {
            arguments += ["--label", labels.joined(separator: ",")]
        }
        if assignees.isEmpty == false {
            arguments += ["--assignee", assignees.joined(separator: ",")]
        }
        let result = try await run(arguments)
        let output = String(decoding: result.standardOutput, as: UTF8.self)
        let issueURL = output
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
            .first(where: { parseIssueURL($0) != nil })

        guard let issueURL else {
            throw GitHubError.issueCreatedButNotAdded(nil)
        }

        do {
            try await addExistingItem(projectId: projectId, url: issueURL)
        } catch {
            throw GitHubError.issueCreatedButNotAdded(issueURL)
        }
        return issueURL
    }

    func searchItems(query: String) async throws -> [GitHubItemCandidate] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return [] }

        let payload: ItemSearchPayload = try await request(
            GraphQLQueries.searchItems,
            variables: ["searchQuery": query],
            as: ItemSearchPayload.self
        )
        return payload.search.nodes.compactMap { node in
            let contentType: ItemContentType
            switch node.typename {
            case "Issue": contentType = .issue
            case "PullRequest": contentType = .pullRequest
            default: return nil
            }
            return GitHubItemCandidate(
                id: node.id,
                contentType: contentType,
                title: node.title,
                number: node.number,
                url: node.url,
                repository: node.repository.nameWithOwner
            )
        }
    }

    func addExistingItem(projectId: String, url: String) async throws {
        guard let item = parseIssueURL(url) else {
            throw GitHubError.invalidItemURL
        }
        let result = try await run([
            "api",
            "repos/\(item.owner)/\(item.repository)/issues/\(item.number)",
            "--jq", ".node_id"
        ])
        let contentId = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard contentId.isEmpty == false else {
            throw GitHubError.decodingError("GitHub returned no item identifier.")
        }
        try await addExistingItem(projectId: projectId, contentId: contentId)
    }

    func addExistingItem(projectId: String, candidate: GitHubItemCandidate) async throws {
        try await addExistingItem(projectId: projectId, contentId: candidate.id)
    }

    private func addExistingItem(projectId: String, contentId: String) async throws {
        let _: EmptyPayload = try await request(
            GraphQLQueries.addItemToProject,
            variables: ["projectId": projectId, "contentId": contentId],
            as: EmptyPayload.self
        )
    }

    private func fetchProjectFields(projectID: String) async throws -> ProjectFieldsResult {
        var after: String?
        var metadata: ProjectFieldsPayload.ProjectNode?
        var fields: [FieldNode] = []

        repeat {
            try Task.checkCancellation()
            var variables = cursorVariables(after)
            variables["id"] = projectID
            let payload: ProjectFieldsPayload = try await request(
                GraphQLQueries.projectFields,
                variables: variables,
                as: ProjectFieldsPayload.self
            )
            guard let node = payload.node else {
                throw GitHubError.graphQLError("Project not found or no longer accessible.")
            }
            metadata = metadata ?? node
            fields.append(contentsOf: node.fields.nodes)
            after = try nextCursor(from: node.fields.pageInfo)
        } while after != nil

        guard let metadata else {
            throw GitHubError.decodingError("Project metadata is missing.")
        }
        return ProjectFieldsResult(
            title: metadata.title,
            number: metadata.number,
            url: metadata.url,
            viewerCanUpdate: metadata.viewerCanUpdate,
            fields: fields
        )
    }

    private func fetchProjectItemNodes(projectID: String) async throws -> [ItemNode] {
        var after: String?
        var items: [ItemNode] = []

        repeat {
            try Task.checkCancellation()
            var variables = cursorVariables(after)
            variables["id"] = projectID
            let payload: ProjectItemsPayload = try await request(
                GraphQLQueries.projectItems,
                variables: variables,
                as: ProjectItemsPayload.self
            )
            guard let node = payload.node else {
                throw GitHubError.graphQLError("Project not found or no longer accessible.")
            }
            items.append(contentsOf: node.items.nodes)
            after = try nextCursor(from: node.items.pageInfo)
        } while after != nil

        return items
    }

    private func makeProjectItem(from node: ItemNode) -> ProjectItem {
        guard let content = node.content else {
            return ProjectItem(
                id: node.id,
                contentId: nil,
                contentType: .redacted,
                title: "Unavailable item",
                number: nil,
                url: nil,
                issueState: nil,
                prState: nil,
                updatedAt: nil,
                status: node.fieldValueByName?.name,
                statusOptionId: node.fieldValueByName?.optionId,
                assignees: [],
                fieldValues: makeFieldValues(node.fieldValues?.nodes ?? [])
            )
        }

        let contentType: ItemContentType
        switch content.typename {
        case "Issue": contentType = .issue
        case "PullRequest": contentType = .pullRequest
        case "DraftIssue": contentType = .draftIssue
        default: contentType = .redacted
        }

        let assignees = content.assignees?.nodes.map {
            Assignee(login: $0.login, avatarUrl: $0.avatarUrl, name: $0.name)
        } ?? []
        let labels = content.labels?.nodes.map {
            IssueLabel(id: $0.id, name: $0.name, color: $0.color)
        } ?? []
        let linkedPullRequest = content.closedByPullRequestsReferences?.nodes.first.map {
            LinkedPR(
                number: $0.number,
                title: $0.title,
                url: $0.url,
                merged: $0.merged,
                closed: $0.closed
            )
        }
        let engineeringSignals = EngineeringSignals(
            isDraft: content.isDraft ?? false,
            mergeability: content.mergeable.flatMap(PullRequestMergeability.init),
            reviewDecision: content.reviewDecision.flatMap(PullRequestReviewDecision.init),
            checkStatus: content.statusCheckRollup?.state.flatMap(CheckStatus.init),
            reviewRequestedLogins: content.reviewRequests?.nodes.compactMap {
                $0.requestedReviewer?.login
            } ?? [],
            subIssueProgress: content.subIssuesSummary.flatMap {
                $0.total > 0 ? SubIssueProgress(completed: $0.completed, total: $0.total) : nil
            },
            blockedByCount: content.blockedBy?.totalCount ?? 0,
            blockingCount: content.blocking?.totalCount ?? 0
        )

        return ProjectItem(
            id: node.id,
            contentId: content.id,
            contentType: contentType,
            title: content.title,
            number: content.number,
            url: content.url,
            issueState: contentType == .issue ? content.state.flatMap(IssueState.init) : nil,
            prState: contentType == .pullRequest ? content.state.flatMap(PullRequestState.init) : nil,
            updatedAt: content.updatedAt,
            status: node.fieldValueByName?.name,
            statusOptionId: node.fieldValueByName?.optionId,
            assignees: assignees,
            labels: labels,
            fieldValues: makeFieldValues(node.fieldValues?.nodes ?? []),
            linkedPR: linkedPullRequest,
            engineeringSignals: engineeringSignals
        )
    }

    private func makeProjectField(from node: FieldNode) -> ProjectField? {
        guard let id = node.id, let name = node.name else { return nil }
        let kind: ProjectFieldKind
        switch node.isIssueField == true ? nil : node.dataType {
        case "SINGLE_SELECT": kind = .singleSelect
        case "ITERATION": kind = .iteration
        case "DATE": kind = .date
        case "NUMBER": kind = .number
        case "TEXT": kind = .text
        default: kind = .unsupported
        }
        let iterations = (node.configuration?.iterations ?? [])
            + (node.configuration?.completedIterations ?? [])
        return ProjectField(
            id: id,
            name: name,
            kind: kind,
            options: node.options?.map {
                ProjectFieldOption(id: $0.id, name: $0.name, color: $0.color)
            } ?? [],
            iterations: iterations.map {
                ProjectIteration(
                    id: $0.id,
                    title: $0.title,
                    startDate: $0.startDate,
                    duration: $0.duration
                )
            }
        )
    }

    private func makeFieldValues(_ nodes: [ItemFieldValueNode]) -> [String: ProjectFieldValue] {
        var values: [String: ProjectFieldValue] = [:]
        for node in nodes {
            guard let fieldId = node.field?.id else { continue }
            switch node.typename {
            case "ProjectV2ItemFieldSingleSelectValue":
                if let optionId = node.optionId, let name = node.name {
                    values[fieldId] = .singleSelect(optionId: optionId, name: name)
                }
            case "ProjectV2ItemFieldIterationValue":
                if let iterationId = node.iterationId, let title = node.title {
                    values[fieldId] = .iteration(id: iterationId, title: title)
                }
            case "ProjectV2ItemFieldDateValue":
                if let date = node.date { values[fieldId] = .date(date) }
            case "ProjectV2ItemFieldNumberValue":
                if let number = node.number { values[fieldId] = .number(number) }
            case "ProjectV2ItemFieldTextValue":
                if let text = node.text { values[fieldId] = .text(text) }
            default:
                continue
            }
        }
        return values
    }

    private func request<Payload: Decodable>(
        _ query: String,
        variables: [String: String] = [:],
        numberVariables: [String: Double] = [:],
        as type: Payload.Type
    ) async throws -> Payload {
        var arguments = ["api", "graphql", "-f", "query=\(query)"]
        for key in variables.keys.sorted() {
            guard let value = variables[key] else { continue }
            arguments += ["-f", "\(key)=\(value)"]
        }
        for key in numberVariables.keys.sorted() {
            guard let value = numberVariables[key] else { continue }
            arguments += ["-F", "\(key)=\(value)"]
        }

        let result = try await run(arguments)
        do {
            let envelope = try decoder.decode(GraphQLEnvelope<Payload>.self, from: result.standardOutput)
            if let errors = envelope.errors, errors.isEmpty == false {
                throw classifyGraphQLErrors(errors)
            }
            guard let payload = envelope.data else {
                throw GitHubError.decodingError("GitHub returned no data.")
            }
            return payload
        } catch let error as GitHubError {
            throw error
        } catch {
            throw GitHubError.decodingError(error.localizedDescription)
        }
    }

    private func run(_ arguments: [String]) async throws -> GitHubCommandResult {
        do {
            return try await runner.run(arguments: arguments)
        } catch is CancellationError {
            throw CancellationError()
        } catch GitHubCommandError.executableNotFound {
            throw GitHubError.ghCLINotFound
        } catch let error as GitHubCommandError {
            let message = error.localizedDescription
            let lowercased = message.lowercased()
            if lowercased.contains("authentication") || lowercased.contains("auth login") {
                throw GitHubError.notAuthenticated
            }
            throw GitHubError.processError(message)
        }
    }

    private func classifyGraphQLErrors(_ errors: [GraphQLIssue]) -> GitHubError {
        let message = errors.map(\.message).joined(separator: "\n")
        let lowercased = message.lowercased()

        if lowercased.contains("scope") && lowercased.contains("project") {
            return .missingProjectScope
        }
        if lowercased.contains("rate limit") {
            return .rateLimited(nil)
        }
        if lowercased.contains("saml") || lowercased.contains("sso") {
            return .organizationAccess(
                "GitHub organization access requires additional SSO authorization."
            )
        }
        return .graphQLError(String(message.prefix(500)))
    }

    private func nextCursor(from pageInfo: PageInfo) throws -> String? {
        guard pageInfo.hasNextPage else { return nil }
        guard let endCursor = pageInfo.endCursor else {
            throw GitHubError.decodingError("GitHub pagination cursor is missing.")
        }
        return endCursor
    }

    private func cursorVariables(_ cursor: String?) -> [String: String] {
        cursor.map { ["after": $0] } ?? [:]
    }

    private func parseRepository(_ value: String) -> String? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.isEmpty == false }) else { return nil }
        return parts.joined(separator: "/")
    }

    private func parseIssueURL(_ value: String) -> (owner: String, repository: String, number: Int, command: String)? {
        guard let url = URLComponents(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com" else { return nil }
        let path = url.path.split(separator: "/")
        guard path.count == 4,
              path[2] == "issues" || path[2] == "pull",
              let number = Int(path[3]) else { return nil }
        return (
            String(path[0]),
            String(path[1]),
            number,
            path[2] == "pull" ? "pr" : "issue"
        )
    }
}

private struct GraphQLEnvelope<Payload: Decodable>: Decodable {
    let data: Payload?
    let errors: [GraphQLIssue]?
}

private struct GraphQLIssue: Decodable {
    let message: String
}

private struct EmptyPayload: Decodable {}

private struct PageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

private struct SessionPayload: Decodable {
    let viewer: Viewer

    struct Viewer: Decodable {
        let id: String
        let login: String
    }
}

private struct OwnersPayload: Decodable {
    let viewer: Viewer

    struct Viewer: Decodable {
        let id: String
        let login: String
        let name: String?
        let organizations: Organizations
    }

    struct Organizations: Decodable {
        let nodes: [OwnerNode]
        let pageInfo: PageInfo
    }

    struct OwnerNode: Decodable {
        let id: String
        let login: String
        let name: String?
    }
}

private struct ProjectsPayload: Decodable {
    let owner: Owner?

    struct Owner: Decodable {
        let projectsV2: ProjectsConnection
    }

    struct ProjectsConnection: Decodable {
        let nodes: [ProjectNode]
        let pageInfo: PageInfo
    }

    struct ProjectNode: Decodable {
        let id: String
        let title: String
        let number: Int
        let url: String
        let viewerCanUpdate: Bool
    }
}

private struct ProjectFieldsPayload: Decodable {
    let node: ProjectNode?

    struct ProjectNode: Decodable {
        let title: String
        let number: Int
        let url: String
        let viewerCanUpdate: Bool
        let fields: FieldsConnection
    }

    struct FieldsConnection: Decodable {
        let nodes: [FieldNode]
        let pageInfo: PageInfo
    }
}

private struct ProjectFieldsResult {
    let title: String
    let number: Int
    let url: String
    let viewerCanUpdate: Bool
    let fields: [FieldNode]
}

private struct FieldNode: Decodable {
    let id: String?
    let name: String?
    let dataType: String?
    let isIssueField: Bool?
    let options: [OptionNode]?
    let configuration: IterationConfiguration?

    struct OptionNode: Decodable {
        let id: String
        let name: String
        let color: String
    }

    struct IterationConfiguration: Decodable {
        let iterations: [IterationNode]
        let completedIterations: [IterationNode]
    }

    struct IterationNode: Decodable {
        let id: String
        let title: String
        let startDate: String
        let duration: Int
    }
}

private struct ProjectItemsPayload: Decodable {
    let node: ProjectNode?

    struct ProjectNode: Decodable {
        let items: ItemsConnection
    }

    struct ItemsConnection: Decodable {
        let nodes: [ItemNode]
        let pageInfo: PageInfo
    }
}

private struct ItemDetailPayload: Decodable {
    let node: Node?

    struct Node: Decodable {
        let typename: String
        let id: String?
        let bodyHTML: String?
        let createdAt: String?
        let updatedAt: String?
        let author: Actor?
        let creator: Actor?
        let viewerCanUpdate: Bool?
        let viewerCanSetMilestone: Bool?
        let repository: RepositoryNode?
        let milestone: MilestoneNode?
        let parent: IssueNode?
        let subIssues: IssueConnection?
        let subIssuesSummary: SubIssuesSummary?
        let blockedBy: IssueConnection?
        let blocking: IssueConnection?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case id
            case bodyHTML
            case createdAt
            case updatedAt
            case author
            case creator
            case viewerCanUpdate
            case viewerCanSetMilestone
            case repository
            case milestone
            case parent
            case subIssues
            case subIssuesSummary
            case blockedBy
            case blocking
        }
    }

    struct Actor: Decodable {
        let login: String
        let avatarUrl: String?
    }

    struct RepositoryNode: Decodable {
        let nameWithOwner: String
    }

    struct MilestoneNode: Decodable {
        let id: String
        let number: Int
        let title: String
        let dueOn: String?
        let state: String
        let progressPercentage: Double
    }

    struct IssueNode: Decodable {
        let id: String
        let number: Int
        let title: String
        let url: String
        let state: String
        let repository: RepositoryNode
    }

    struct IssueConnection: Decodable {
        let nodes: [IssueNode]
    }

    struct SubIssuesSummary: Decodable {
        let completed: Int
        let total: Int
    }
}

private struct ItemNode: Decodable {
    let id: String
    let content: ItemContent?
    let fieldValueByName: FieldValue?
    let fieldValues: FieldValuesConnection?

    struct ItemContent: Decodable {
        let typename: String
        let id: String
        let title: String
        let number: Int?
        let url: String?
        let state: String?
        let updatedAt: String?
        let assignees: AssigneesConnection?
        let labels: LabelsConnection?
        let closedByPullRequestsReferences: PullRequestsConnection?
        let isDraft: Bool?
        let mergeable: String?
        let reviewDecision: String?
        let reviewRequests: ReviewRequestsConnection?
        let statusCheckRollup: StatusCheckRollup?
        let subIssuesSummary: SubIssuesSummary?
        let blockedBy: CountConnection?
        let blocking: CountConnection?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case id
            case title
            case number
            case url
            case state
            case updatedAt
            case assignees
            case labels
            case closedByPullRequestsReferences
            case isDraft, mergeable, reviewDecision, reviewRequests, statusCheckRollup
            case subIssuesSummary, blockedBy, blocking
        }
    }

    struct ReviewRequestsConnection: Decodable {
        let nodes: [ReviewRequestNode]
    }

    struct ReviewRequestNode: Decodable {
        let requestedReviewer: RequestedReviewer?
    }

    struct RequestedReviewer: Decodable {
        let login: String?
    }

    struct StatusCheckRollup: Decodable {
        let state: String?
    }

    struct SubIssuesSummary: Decodable {
        let completed: Int
        let total: Int
    }

    struct CountConnection: Decodable {
        let totalCount: Int
    }

    struct AssigneesConnection: Decodable {
        let nodes: [AssigneeNode]
    }

    struct AssigneeNode: Decodable {
        let login: String
        let avatarUrl: String
        let name: String?
    }

    struct LabelsConnection: Decodable {
        let nodes: [LabelNode]
    }

    struct LabelNode: Decodable {
        let id: String
        let name: String
        let color: String
    }

    struct PullRequestsConnection: Decodable {
        let nodes: [PullRequestNode]
    }

    struct PullRequestNode: Decodable {
        let number: Int
        let title: String
        let url: String
        let merged: Bool
        let closed: Bool
    }

    struct FieldValue: Decodable {
        let name: String?
        let optionId: String?
    }

    struct FieldValuesConnection: Decodable {
        let nodes: [ItemFieldValueNode]
    }
}

private struct ItemFieldValueNode: Decodable {
    let typename: String
    let name: String?
    let optionId: String?
    let title: String?
    let iterationId: String?
    let date: String?
    let number: Double?
    let text: String?
    let field: FieldReference?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case name, optionId, title, iterationId, date, number, text, field
    }

    struct FieldReference: Decodable {
        let id: String?
    }
}

private struct UserSearchPayload: Decodable {
    let search: SearchConnection

    struct SearchConnection: Decodable {
        let nodes: [UserNode]
    }

    struct UserNode: Decodable {
        let login: String?
        let avatarUrl: String?
        let name: String?
    }
}

private struct ItemSearchPayload: Decodable {
    let search: SearchConnection

    struct SearchConnection: Decodable {
        let nodes: [ItemNode]
    }

    struct ItemNode: Decodable {
        let typename: String
        let id: String
        let title: String
        let number: Int
        let url: String
        let repository: Repository

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case id, title, number, url, repository
        }
    }

    struct Repository: Decodable {
        let nameWithOwner: String
    }
}

private struct DraftIssuePayload: Decodable {
    let addProjectV2DraftIssue: DraftIssueResult

    struct DraftIssueResult: Decodable {
        let projectItem: ProjectItemResult
    }

    struct ProjectItemResult: Decodable {
        let id: String
    }
}
