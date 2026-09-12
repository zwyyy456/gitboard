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
    case issueCreationUnconfirmed
    case issueCreationNotStarted(String)
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
            return "GitStride needs the GitHub project scope. Run 'gh auth refresh -s project' in Terminal."
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
        case .issueCreationUnconfirmed:
            return "GitHub did not confirm the issue’s identity. Check the repository before creating another issue."
        case .issueCreationNotStarted(let message):
            return "The issue was not created. \(message)"
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
            let payload: GitHubResponse.SessionPayload = try await request(
                GraphQLQueries.sessionProbe,
                as: GitHubResponse.SessionPayload.self
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
            let payload: GitHubResponse.OwnersPayload = try await request(
                GraphQLQueries.owners,
                variables: cursorVariables(after),
                as: GitHubResponse.OwnersPayload.self
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

    func deleteProject(id: String) async throws {
        let _: GitHubResponse.DeleteProjectPayload = try await request(
            GraphQLQueries.deleteProject,
            variables: ["projectId": id],
            as: GitHubResponse.DeleteProjectPayload.self
        )
    }

    func createProject(owner: ProjectOwner, title: String, repositoryID: String? = nil) async throws -> Project {
        var variables = ["ownerId": owner.id, "title": title]
        variables["repositoryId"] = repositoryID
        let payload: GitHubResponse.CreateProjectPayload = try await request(
            GraphQLQueries.createProject,
            variables: variables,
            as: GitHubResponse.CreateProjectPayload.self
        )
        let project = payload.createProjectV2.projectV2
        return Project(
            id: project.id, owner: owner, title: project.title,
            number: project.number, url: project.url,
            viewerCanUpdate: project.viewerCanUpdate
        )
    }

    func fetchRepositories(owner: ProjectOwner) async throws -> [ProjectRepository] {
        var after: String?
        var repositories: [ProjectRepository] = []
        repeat {
            try Task.checkCancellation()
            var variables = cursorVariables(after)
            variables["login"] = owner.login
            let payload: GitHubResponse.OwnerRepositoriesPayload = try await request(
                GraphQLQueries.ownerRepositories, variables: variables,
                as: GitHubResponse.OwnerRepositoriesPayload.self
            )
            guard let connection = payload.repositoryOwner?.repositories else {
                throw GitHubError.graphQLError("Repositories are not accessible for this owner.")
            }
            repositories += connection.nodes.map {
                ProjectRepository(id: $0.id, nameWithOwner: $0.nameWithOwner, ownerID: owner.id)
            }
            after = try nextCursor(from: connection.pageInfo)
        } while after != nil
        return repositories
    }

    func linkProjectRepository(projectID: String, repositoryID: String) async throws {
        let _: GitHubResponse.LinkProjectRepositoryPayload = try await request(
            GraphQLQueries.linkProjectRepository,
            variables: ["projectId": projectID, "repositoryId": repositoryID],
            as: GitHubResponse.LinkProjectRepositoryPayload.self
        )
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

            let payload: GitHubResponse.ProjectsPayload = try await request(
                query,
                variables: variables,
                as: GitHubResponse.ProjectsPayload.self
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
            linkedRepositories: projectData.linkedRepositories,
            fields: fields,
            statusField: statusField,
            items: itemNodes.map(makeProjectItem)
        )
    }

    func fetchItemDetail(contentID: String) async throws -> ProjectItemDetail {
        let payload: GitHubResponse.ItemDetailPayload = try await request(
            GraphQLQueries.itemDetail,
            variables: ["id": contentID],
            as: GitHubResponse.ItemDetailPayload.self
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

    private func makeIssueReference(_ node: GitHubResponse.ItemDetailPayload.IssueNode) -> IssueReference? {
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

    private func makeMilestone(_ node: GitHubResponse.ItemDetailPayload.MilestoneNode) -> RepositoryMilestone? {
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

    func fetchRepositoryMilestones(repository value: String) async throws -> [RepositoryMilestone] {
        guard let repository = parseRepository(value) else {
            throw GitHubError.invalidRepository
        }
        let components = repository.split(separator: "/").map(String.init)
        var after: String?
        var milestones: [RepositoryMilestone] = []

        repeat {
            try Task.checkCancellation()
            var variables = cursorVariables(after)
            variables["owner"] = components[0]
            variables["name"] = components[1]
            let payload: GitHubResponse.RepositoryMilestonesPayload = try await request(
                GraphQLQueries.repositoryMilestones,
                variables: variables,
                as: GitHubResponse.RepositoryMilestonesPayload.self
            )
            guard let connection = payload.repository?.milestones else {
                throw GitHubError.graphQLError("Repository not found or no longer accessible.")
            }
            milestones.append(contentsOf: connection.nodes.compactMap(makeMilestone))
            after = try nextCursor(from: connection.pageInfo)
        } while after != nil

        return milestones
    }

    func updateIssueMilestone(issueID: String, milestoneID: String?) async throws {
        let query: String
        var variables = ["issueId": issueID]
        if let milestoneID {
            query = GraphQLQueries.setIssueMilestone
            variables["milestoneId"] = milestoneID
        } else {
            query = GraphQLQueries.clearIssueMilestone
        }
        let _: GitHubResponse.EmptyPayload = try await request(
            query,
            variables: variables,
            as: GitHubResponse.EmptyPayload.self
        )
    }

    func addSubIssue(
        parentIssueID: String,
        subIssueID: String,
        replacingParent: Bool
    ) async throws {
        let _: GitHubResponse.EmptyPayload = try await request(
            replacingParent ? GraphQLQueries.replaceSubIssueParent : GraphQLQueries.addSubIssue,
            variables: ["issueId": parentIssueID, "subIssueId": subIssueID],
            as: GitHubResponse.EmptyPayload.self
        )
    }

    func removeSubIssue(parentIssueID: String, subIssueID: String) async throws {
        let _: GitHubResponse.EmptyPayload = try await request(
            GraphQLQueries.removeSubIssue,
            variables: ["issueId": parentIssueID, "subIssueId": subIssueID],
            as: GitHubResponse.EmptyPayload.self
        )
    }

    func addBlockedBy(issueID: String, blockingIssueID: String) async throws {
        let _: GitHubResponse.EmptyPayload = try await request(
            GraphQLQueries.addBlockedBy,
            variables: ["issueId": issueID, "blockingIssueId": blockingIssueID],
            as: GitHubResponse.EmptyPayload.self
        )
    }

    func removeBlockedBy(issueID: String, blockingIssueID: String) async throws {
        let _: GitHubResponse.EmptyPayload = try await request(
            GraphQLQueries.removeBlockedBy,
            variables: ["issueId": issueID, "blockingIssueId": blockingIssueID],
            as: GitHubResponse.EmptyPayload.self
        )
    }

    func updateItemStatus(
        projectId: String,
        itemId: String,
        fieldId: String,
        optionId: String
    ) async throws {
        let _: GitHubResponse.EmptyPayload = try await request(
            GraphQLQueries.updateItemStatus,
            variables: [
                "projectId": projectId,
                "itemId": itemId,
                "fieldId": fieldId,
                "optionId": optionId
            ],
            as: GitHubResponse.EmptyPayload.self
        )
    }

    func updateItemField(
        projectId: String,
        itemId: String,
        fieldId: String,
        value: ProjectFieldValue?
    ) async throws {
        guard let value else {
            let _: GitHubResponse.EmptyPayload = try await request(
                GraphQLQueries.clearItemField,
                variables: ["projectId": projectId, "itemId": itemId, "fieldId": fieldId],
                as: GitHubResponse.EmptyPayload.self
            )
            return
        }

        let variables = ["projectId": projectId, "itemId": itemId, "fieldId": fieldId]
        switch value {
        case .singleSelect(let optionId, _):
            let _: GitHubResponse.EmptyPayload = try await request(
                GraphQLQueries.updateItemStatus,
                variables: variables.merging(["optionId": optionId]) { _, new in new },
                as: GitHubResponse.EmptyPayload.self
            )
        case .iteration(let id, _):
            let _: GitHubResponse.EmptyPayload = try await request(
                GraphQLQueries.updateIterationField,
                variables: variables.merging(["iterationId": id]) { _, new in new },
                as: GitHubResponse.EmptyPayload.self
            )
        case .date(let date):
            let _: GitHubResponse.EmptyPayload = try await request(
                GraphQLQueries.updateDateField,
                variables: variables.merging(["date": date]) { _, new in new },
                as: GitHubResponse.EmptyPayload.self
            )
        case .number(let number):
            let _: GitHubResponse.EmptyPayload = try await request(
                GraphQLQueries.updateNumberField,
                variables: variables,
                numberVariables: ["number": number],
                as: GitHubResponse.EmptyPayload.self
            )
        case .text(let text):
            let _: GitHubResponse.EmptyPayload = try await request(
                GraphQLQueries.updateTextField,
                variables: variables.merging(["text": text]) { _, new in new },
                as: GitHubResponse.EmptyPayload.self
            )
        }
    }

    func archiveItem(projectId: String, itemId: String) async throws {
        let _: GitHubResponse.EmptyPayload = try await request(
            GraphQLQueries.archiveItem,
            variables: ["projectId": projectId, "itemId": itemId],
            as: GitHubResponse.EmptyPayload.self
        )
    }

    func deleteItem(projectId: String, itemId: String) async throws {
        let _: GitHubResponse.EmptyPayload = try await request(
            GraphQLQueries.deleteItem,
            variables: ["projectId": projectId, "itemId": itemId],
            as: GitHubResponse.EmptyPayload.self
        )
    }

    func searchUsers(query: String) async throws -> [Assignee] {
        let payload: GitHubResponse.UserSearchPayload = try await request(
            GraphQLQueries.searchUsers,
            variables: ["query": query],
            as: GitHubResponse.UserSearchPayload.self
        )
        return payload.search.nodes.compactMap { node in
            guard let login = node.login, let avatarURL = node.avatarUrl else {
                return nil
            }
            return Assignee(login: login, avatarUrl: avatarURL, name: node.name)
        }
    }

    func addAssignee(issueUrl: String, userLogin: String) async throws {
        guard let components = GitHubItemAddress(issueUrl) else {
            throw GitHubError.graphQLError("Invalid issue URL")
        }
        _ = try await run([
            components.command, "edit", String(components.number),
            "--repo", "\(components.owner)/\(components.repository)",
            "--add-assignee", userLogin
        ])
    }

    func removeAssignee(issueUrl: String, userLogin: String) async throws {
        guard let components = GitHubItemAddress(issueUrl) else {
            throw GitHubError.graphQLError("Invalid issue URL")
        }
        _ = try await run([
            components.command, "edit", String(components.number),
            "--repo", "\(components.owner)/\(components.repository)",
            "--remove-assignee", userLogin
        ])
    }

    func addLabel(issueUrl: String, label: String) async throws {
        guard let components = GitHubItemAddress(issueUrl) else {
            throw GitHubError.invalidItemURL
        }
        _ = try await run([
            components.command, "edit", String(components.number),
            "--repo", "\(components.owner)/\(components.repository)",
            "--add-label", label
        ])
    }

    func removeLabel(issueUrl: String, label: String) async throws {
        guard let components = GitHubItemAddress(issueUrl) else {
            throw GitHubError.invalidItemURL
        }
        _ = try await run([
            components.command, "edit", String(components.number),
            "--repo", "\(components.owner)/\(components.repository)",
            "--remove-label", label
        ])
    }

    func createDraftIssue(projectId: String, title: String, body: String) async throws -> String {
        let payload: GitHubResponse.DraftIssuePayload = try await request(
            GraphQLQueries.addDraftIssue,
            variables: ["projectId": projectId, "title": title, "body": body],
            as: GitHubResponse.DraftIssuePayload.self
        )
        return payload.addProjectV2DraftIssue.projectItem.id
    }

    func createIssue(
        repository: String,
        title: String,
        body: String,
        labels: [String] = [],
        assignees: [String] = []
    ) async throws -> String {
        guard let repository = parseRepository(repository) else {
            throw GitHubError.invalidRepository
        }
        let repositoryID: String
        var labelIDs: [String] = []
        var assigneeIDs: [String] = []
        do {
            let parts = repository.split(separator: "/").map(String.init)
            var after: String?
            var existingLabels: [GitHubResponse.IssueLabel] = []
            var resolvedRepositoryID: String?
            repeat {
                try Task.checkCancellation()
                var variables = cursorVariables(after)
                variables["owner"] = parts[0]
                variables["name"] = parts[1]
                let payload: GitHubResponse.IssueRepositoryPayload = try await request(
                    GraphQLQueries.issueRepository, variables: variables,
                    as: GitHubResponse.IssueRepositoryPayload.self
                )
                guard let remoteRepository = payload.repository else {
                    throw GitHubError.graphQLError("Repository not found or no longer accessible.")
                }
                resolvedRepositoryID = remoteRepository.id
                existingLabels += remoteRepository.labels.nodes
                after = labels.isEmpty ? nil : try nextCursor(from: remoteRepository.labels.pageInfo)
            } while after != nil
            guard let resolvedRepositoryID else { throw GitHubError.invalidRepository }
            repositoryID = resolvedRepositoryID

            for login in Set(assignees).sorted() {
                try Task.checkCancellation()
                let payload: GitHubResponse.IssueAssigneePayload = try await request(
                    GraphQLQueries.issueAssignee, variables: ["login": login],
                    as: GitHubResponse.IssueAssigneePayload.self
                )
                guard let user = payload.user else {
                    throw GitHubError.graphQLError("Assignee @\(login) was not found.")
                }
                assigneeIDs.append(user.id)
            }

            for name in labels {
                try Task.checkCancellation()
                let label: GitHubResponse.IssueLabel
                if let existing = existingLabels.first(where: {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame
                }) {
                    label = existing
                } else {
                    let payload: GitHubResponse.CreateLabelPayload = try await request(
                        GraphQLQueries.createLabel,
                        variables: ["repositoryId": repositoryID, "name": name],
                        as: GitHubResponse.CreateLabelPayload.self
                    )
                    label = payload.createLabel.label
                    existingLabels.append(label)
                }
                if !labelIDs.contains(label.id) { labelIDs.append(label.id) }
            }
            try Task.checkCancellation()
        } catch {
            // Reads and label creation cannot create an issue, even if interrupted.
            throw GitHubError.issueCreationNotStarted(error.localizedDescription)
        }

        let payload: GitHubResponse.CreateIssuePayload = try await request(
            GraphQLQueries.createIssue,
            variables: ["repositoryId": repositoryID, "title": title, "body": body],
            arrayVariables: ["labelIds": labelIDs, "assigneeIds": assigneeIDs],
            as: GitHubResponse.CreateIssuePayload.self
        )
        let issueURL = payload.createIssue.issue.url
        guard GitHubItemAddress(issueURL) != nil else {
            throw GitHubError.issueCreationUnconfirmed
        }
        return issueURL
    }

    func searchItems(query: String) async throws -> [GitHubItemCandidate] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return [] }

        let payload: GitHubResponse.ItemSearchPayload = try await request(
            GraphQLQueries.searchItems,
            variables: ["searchQuery": query],
            as: GitHubResponse.ItemSearchPayload.self
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

    func resolveItem(url: String) async throws -> GitHubItemCandidate {
        guard GitHubItemAddress(url) != nil else { throw GitHubError.invalidItemURL }
        let payload: GitHubItemResourcePayload = try await request(
            GraphQLQueries.itemAtURL,
            variables: ["url": url],
            as: GitHubItemResourcePayload.self
        )
        guard let candidate = payload.resource else {
            throw GitHubError.graphQLError("Item not found or no longer accessible.")
        }
        return candidate
    }

    func addExistingItem(projectId: String, url: String) async throws -> String {
        guard let item = GitHubItemAddress(url) else {
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
        return try await addExistingItem(projectId: projectId, contentId: contentId)
    }

    func addExistingItem(projectId: String, candidate: GitHubItemCandidate) async throws {
        _ = try await addExistingItem(projectId: projectId, contentId: candidate.id)
    }

    private func addExistingItem(projectId: String, contentId: String) async throws -> String {
        let payload: GitHubResponse.AddProjectItemPayload = try await request(
            GraphQLQueries.addItemToProject,
            variables: ["projectId": projectId, "contentId": contentId],
            as: GitHubResponse.AddProjectItemPayload.self
        )
        return payload.addProjectV2ItemById.item.id
    }

    private func fetchProjectFields(projectID: String) async throws -> ProjectFieldsResult {
        var after: String?
        var repositoryAfter: String?
        var metadata: GitHubResponse.ProjectFieldsPayload.ProjectNode?
        var fields: [GitHubResponse.FieldNode] = []
        var repositories: [String] = []

        repeat {
            try Task.checkCancellation()
            var variables = cursorVariables(after)
            variables["id"] = projectID
            variables["repositoryAfter"] = repositoryAfter
            let payload: GitHubResponse.ProjectFieldsPayload = try await request(
                GraphQLQueries.projectFields,
                variables: variables,
                as: GitHubResponse.ProjectFieldsPayload.self
            )
            guard let node = payload.node else {
                throw GitHubError.graphQLError("Project not found or no longer accessible.")
            }
            if metadata == nil || after != nil {
                fields.append(contentsOf: node.fields.nodes)
                after = try nextCursor(from: node.fields.pageInfo)
            }
            if metadata == nil || repositoryAfter != nil {
                repositories += node.repositories.nodes.map(\.nameWithOwner)
                repositoryAfter = try nextCursor(from: node.repositories.pageInfo)
            }
            metadata = metadata ?? node
        } while after != nil || repositoryAfter != nil

        guard let metadata else {
            throw GitHubError.decodingError("Project metadata is missing.")
        }
        return ProjectFieldsResult(
            title: metadata.title,
            number: metadata.number,
            url: metadata.url,
            viewerCanUpdate: metadata.viewerCanUpdate,
            linkedRepositories: repositories,
            fields: fields
        )
    }

    private func fetchProjectItemNodes(projectID: String) async throws -> [GitHubResponse.ItemNode] {
        var after: String?
        var items: [GitHubResponse.ItemNode] = []

        repeat {
            try Task.checkCancellation()
            var variables = cursorVariables(after)
            variables["id"] = projectID
            let payload: GitHubResponse.ProjectItemsPayload = try await request(
                GraphQLQueries.projectItems,
                variables: variables,
                as: GitHubResponse.ProjectItemsPayload.self
            )
            guard let node = payload.node else {
                throw GitHubError.graphQLError("Project not found or no longer accessible.")
            }
            items.append(contentsOf: node.items.nodes)
            after = try nextCursor(from: node.items.pageInfo)
        } while after != nil

        return items
    }

    private func makeProjectItem(from node: GitHubResponse.ItemNode) -> ProjectItem {
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
            blockedByCount: content.issueDependenciesSummary?.blockedBy ?? 0,
            blockingCount: content.issueDependenciesSummary?.blocking ?? 0
        )

        var item = ProjectItem(
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
        item.milestone = content.milestone.map {
            ProjectPlanningReference(id: $0.id, title: $0.title, repository: item.repositoryName ?? "", number: nil)
        }
        item.parentIssue = content.parent.map {
            ProjectPlanningReference(id: $0.id, title: $0.title, repository: $0.repository?.nameWithOwner ?? "", number: $0.number)
        }
        item.issueType = content.issueType
        return item
    }

    private func makeProjectField(from node: GitHubResponse.FieldNode) -> ProjectField? {
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

    private func makeFieldValues(_ nodes: [GitHubResponse.ItemFieldValueNode]) -> [String: ProjectFieldValue] {
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
        arrayVariables: [String: [String]] = [:],
        as type: Payload.Type
    ) async throws -> Payload {
        var arguments = ["api", "graphql", "-f", "query=\(query)"]
        for key in variables.keys.sorted() {
            guard let value = variables[key] else { continue }
            arguments += ["-f", "\(key)=\(value)"]
        }
        var input: Data?
        if !numberVariables.isEmpty || !arrayVariables.isEmpty {
            var values: [String: Any] = variables
            for (key, value) in numberVariables { values[key] = value }
            for (key, value) in arrayVariables { values[key] = value }
            input = try JSONSerialization.data(withJSONObject: ["query": query, "variables": values])
            arguments = ["api", "graphql", "--input", "-"]
        }

        let result = try await run(arguments, standardInput: input)
        do {
            let issues = try decoder.decode(GitHubResponse.GraphQLErrorResponse.self, from: result.standardOutput)
            if let errors = issues.errors, !errors.isEmpty { throw classifyGraphQLErrors(errors) }
            let envelope = try decoder.decode(GitHubResponse.GraphQLEnvelope<Payload>.self, from: result.standardOutput)
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

    private func run(_ arguments: [String], standardInput: Data? = nil) async throws -> GitHubCommandResult {
        do {
            return try await runner.run(arguments: arguments, standardInput: standardInput)
        } catch is CancellationError {
            throw CancellationError()
        } catch GitHubCommandError.executableNotFound {
            throw GitHubError.ghCLINotFound
        } catch let error as GitHubCommandError {
            if arguments.starts(with: ["api", "graphql"]),
               case .failed(_, _, let output) = error,
               let response = try? decoder.decode(GitHubResponse.GraphQLErrorResponse.self, from: output),
               let errors = response.errors, !errors.isEmpty {
                throw classifyGraphQLErrors(errors)
            }
            let message = error.localizedDescription
            let lowercased = message.lowercased()
            if lowercased.contains("authentication") || lowercased.contains("auth login") {
                throw GitHubError.notAuthenticated
            }
            throw GitHubError.processError(message)
        }
    }

    private func classifyGraphQLErrors(_ errors: [GitHubResponse.GraphQLIssue]) -> GitHubError {
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

    private func nextCursor(from pageInfo: GitHubResponse.PageInfo) throws -> String? {
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


    private struct ProjectFieldsResult {
        let title: String
        let number: Int
        let url: String
        let viewerCanUpdate: Bool
        let linkedRepositories: [String]
        let fields: [GitHubResponse.FieldNode]
    }
}
