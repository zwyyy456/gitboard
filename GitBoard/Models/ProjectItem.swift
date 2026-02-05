import Foundation

enum ItemContentType: String, Codable {
    case issue = "ISSUE"
    case pullRequest = "PULL_REQUEST"
    case draftIssue = "DRAFT_ISSUE"
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
    let linkedPR: LinkedPR?

    init(id: String, contentId: String?, contentType: ItemContentType, title: String, number: Int?, url: String?, issueState: IssueState?, prState: PullRequestState?, status: String?, statusOptionId: String?, assignees: [Assignee], linkedPR: LinkedPR? = nil) {
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
        self.linkedPR = linkedPR
    }

    static func == (lhs: ProjectItem, rhs: ProjectItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
