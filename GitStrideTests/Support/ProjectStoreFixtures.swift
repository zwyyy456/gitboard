import Foundation
import Testing
@testable import GitStride

extension ProjectStoreTests {
    static let createdProjectResponse = """
        {"data":{"createProjectV2":{"projectV2":{"id":"NEW","title":"New project","number":9,"url":"https://github.com/users/me/projects/9","viewerCanUpdate":true}}}}
        """

    static func twoItemResponses() throws -> [String] {
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

    func makeStore(
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

    static let sessionResponse =
        #"{"data":{"viewer":{"id":"U1","login":"me"}}}"#

    static let ownersResponse =
        #"{"data":{"viewer":{"id":"U1","login":"me","name":null,"organizations":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#

    static let projectsResponse =
        #"{"data":{"owner":{"projectsV2":{"nodes":[{"id":"P1","title":"One","number":1,"url":"https://github.com/users/me/projects/1","viewerCanUpdate":true},{"id":"P2","title":"Two","number":2,"url":"https://github.com/users/me/projects/2","viewerCanUpdate":true}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#

    static let firstProjectFieldsResponse =
        #"{"data":{"node":{"title":"One","number":1,"url":"https://github.com/users/me/projects/1","viewerCanUpdate":true,"fields":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#

    static let secondProjectFieldsResponse =
        #"{"data":{"node":{"title":"Two","number":2,"url":"https://github.com/users/me/projects/2","viewerCanUpdate":true,"fields":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#

    static let emptyItemsResponse =
        #"{"data":{"node":{"items":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#

    static let emptyProjectResponses = [
        sessionResponse,
        ownersResponse,
        #"{"data":{"owner":{"projectsV2":{"nodes":[{"id":"P1","title":"One","number":1,"url":"https://github.com/users/me/projects/1","viewerCanUpdate":true}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#,
        firstProjectFieldsResponse,
        emptyItemsResponse
    ]

    static let mutationProjectsResponse =
        #"{"data":{"owner":{"projectsV2":{"nodes":[{"id":"P1","title":"One","number":1,"url":"https://github.com/users/me/projects/1","viewerCanUpdate":true}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#

    static let mutationFieldsResponse =
        #"{"data":{"node":{"title":"One","number":1,"url":"https://github.com/users/me/projects/1","viewerCanUpdate":true,"fields":{"nodes":[{"__typename":"ProjectV2SingleSelectField","id":"STATUS","name":"Status","dataType":"SINGLE_SELECT","options":[{"id":"TODO","name":"Todo","color":"GRAY"},{"id":"REVIEW","name":"Review","color":"YELLOW"}]}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#

    static let mutationItemsResponse =
        #"{"data":{"node":{"items":{"nodes":[{"id":"ITEM1","content":{"__typename":"Issue","id":"CONTENT1","title":"Item","number":1,"url":"https://github.com/acme/app/issues/1","state":"OPEN","updatedAt":"2026-08-01T00:00:00Z","assignees":{"nodes":[]},"labels":{"nodes":[]},"closedByPullRequestsReferences":{"nodes":[]}},"fieldValueByName":{"name":"Todo","optionId":"TODO"},"fieldValues":{"nodes":[{"__typename":"ProjectV2ItemFieldSingleSelectValue","name":"Todo","optionId":"TODO","field":{"id":"STATUS"}}]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#

    static let mutationProjectResponses = [sessionResponse, ownersResponse, mutationProjectsResponse, mutationFieldsResponse, mutationItemsResponse]

    static let graphQLFailureResponse =
        #"{"data":null,"errors":[{"message":"Status failed"}]}"#

    static let graphQLSuccessResponse =
        #"{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"P1"}}}}"#

    static func kanbanProject() -> Project {
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

    static func detailItem(updatedAt: String) -> ProjectItem {
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

    static func itemDetailResponse(body: String) -> String {
        #"{"data":{"node":{"__typename":"Issue","id":"CONTENT1","bodyHTML":"\#(body)","createdAt":null,"updatedAt":"2026-08-01T00:00:00Z","author":null,"viewerCanUpdate":false,"viewerCanSetMilestone":false,"repository":{"nameWithOwner":"acme/repo"},"milestone":null,"parent":null,"subIssues":{"nodes":[]},"subIssuesSummary":{"completed":0,"total":0},"blockedBy":{"nodes":[]},"blocking":{"nodes":[]}}}}"#
    }
}
