import Foundation

enum ItemContentType: String, Codable {
    case issue = "ISSUE"
    case pullRequest = "PULL_REQUEST"
    case draftIssue = "DRAFT_ISSUE"
    case redacted = "REDACTED"
}

enum IssueState: String, Codable {
    case open = "OPEN"
    case closed = "CLOSED"
}

enum PullRequestState: String, Codable {
    case open = "OPEN"
    case closed = "CLOSED"
    case merged = "MERGED"
}

struct Assignee: Codable, Identifiable, Hashable {
    let login: String
    let avatarUrl: String
    let name: String?

    var id: String { login }
}

struct LinkedPR: Codable, Hashable {
    let number: Int
    let title: String
    let url: String
    let merged: Bool
    let closed: Bool
}

struct IssueLabel: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let color: String
}

struct ProjectItem: Identifiable, Codable, Hashable {
    let id: String
    let contentId: String?
    let contentType: ItemContentType
    let title: String
    let number: Int?
    let url: String?
    let issueState: IssueState?
    let prState: PullRequestState?
    let status: String?
    let statusOptionId: String?
    let assignees: [Assignee]
    let labels: [IssueLabel]
    let fieldValues: [String: ProjectFieldValue]
    let linkedPR: LinkedPR?

    init(id: String, contentId: String?, contentType: ItemContentType, title: String, number: Int?, url: String?, issueState: IssueState?, prState: PullRequestState?, status: String?, statusOptionId: String?, assignees: [Assignee], labels: [IssueLabel] = [], fieldValues: [String: ProjectFieldValue] = [:], linkedPR: LinkedPR? = nil) {
        self.id = id
        self.contentId = contentId
        self.contentType = contentType
        self.title = title
        self.number = number
        self.url = url
        self.issueState = issueState
        self.prState = prState
        self.status = status
        self.statusOptionId = statusOptionId
        self.assignees = assignees
        self.labels = labels
        self.fieldValues = fieldValues
        self.linkedPR = linkedPR
    }

    static func == (lhs: ProjectItem, rhs: ProjectItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var repositoryName: String? {
        guard let url,
              let components = URLComponents(string: url),
              components.host?.lowercased() == "github.com" else { return nil }
        let path = components.path.split(separator: "/")
        guard path.count >= 4,
              path[2] == "issues" || path[2] == "pull" else { return nil }
        return "\(path[0])/\(path[1])"
    }
}

struct GitHubItemCandidate: Identifiable, Hashable {
    let id: String
    let contentType: ItemContentType
    let title: String
    let number: Int
    let url: String
    let repository: String
}
