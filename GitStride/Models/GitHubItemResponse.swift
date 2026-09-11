import Foundation

extension GitHubResponse {
    struct ProjectItemsPayload: Decodable {
        let node: ProjectNode?

        struct ProjectNode: Decodable {
            let items: ItemsConnection
        }

        struct ItemsConnection: Decodable {
            let nodes: [ItemNode]
            let pageInfo: PageInfo
        }
    }

    struct ItemNode: Decodable {
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
            let milestone: PlanningNode?
            let parent: PlanningNode?
            let issueType: ProjectIssueType?
            let issueDependenciesSummary: DependenciesSummary?

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
                case subIssuesSummary, milestone, parent, issueType, issueDependenciesSummary
            }
        }

        struct PlanningNode: Decodable {
            let id: String
            let title: String
            let number: Int?
            let repository: RepositoryName?
        }

        struct RepositoryName: Decodable { let nameWithOwner: String }
        struct DependenciesSummary: Decodable {
            let blockedBy: Int
            let blocking: Int
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

    struct ItemFieldValueNode: Decodable {
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

    struct ItemSearchPayload: Decodable {
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
}
