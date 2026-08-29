import Foundation

struct ProjectItemDetail: Identifiable, Hashable, Sendable {
    let id: String
    let bodyHTML: String
    let author: ItemAuthor?
    let createdAt: String?
    let updatedAt: String?
    let issueMetadata: IssueMetadata?
}

struct ItemAuthor: Hashable, Sendable {
    let login: String
    let avatarURL: String?
}

struct IssueMetadata: Hashable, Sendable {
    let repository: String
    let milestone: RepositoryMilestone?
    let parent: IssueReference?
    let subIssues: [IssueReference]
    let subIssueProgress: SubIssueProgress?
    let blockedBy: [IssueReference]
    let blocking: [IssueReference]
    let viewerCanUpdate: Bool
    let viewerCanSetMilestone: Bool
}

struct IssueReference: Identifiable, Hashable, Sendable {
    let id: String
    let repository: String
    let number: Int
    let title: String
    let url: URL
    let state: IssueState
}

enum IssueRelationKind: String, CaseIterable, Identifiable, Sendable {
    case parent
    case subIssue
    case blockedBy
    case blocking

    var id: Self { self }

    func endpoints(issueID: String, relatedIssueID: String) -> IssueRelationEndpoints {
        switch self {
        case .parent, .blocking:
            IssueRelationEndpoints(issueID: relatedIssueID, relatedIssueID: issueID)
        case .subIssue, .blockedBy:
            IssueRelationEndpoints(issueID: issueID, relatedIssueID: relatedIssueID)
        }
    }
}

struct IssueRelationEndpoints: Equatable, Sendable {
    let issueID: String
    let relatedIssueID: String
}

enum MilestoneState: String, Hashable, Sendable {
    case open = "OPEN"
    case closed = "CLOSED"
}

struct RepositoryMilestone: Identifiable, Hashable, Sendable {
    let id: String
    let number: Int
    let title: String
    let dueOn: String?
    let state: MilestoneState
    let progressPercentage: Double
}

enum RepositoryMilestonesState: Equatable {
    case idle
    case loading
    case loaded([RepositoryMilestone])
    case failed(String)
}

enum ItemDetailState: Equatable {
    case idle
    case loading
    case loaded(ProjectItemDetail)
    case failed(String)
}
