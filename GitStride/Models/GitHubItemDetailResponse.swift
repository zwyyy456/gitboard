import Foundation

extension GitHubResponse {
    struct ItemDetailPayload: Decodable {
        let node: Node?

        struct Node: Decodable {
            let typename: String
            let id: String?
            let title: String?
            let body: String?
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
                case title
                case body
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

    struct UpdateItemContentPayload: Decodable {
        let update: Update?

        struct Update: Decodable {
            let content: Content?
        }

        struct Content: Decodable {
            let id: String
        }
    }

    struct RepositoryMilestonesPayload: Decodable {
        let repository: Repository?

        struct Repository: Decodable {
            let milestones: MilestonesConnection
        }

        struct MilestonesConnection: Decodable {
            let nodes: [ItemDetailPayload.MilestoneNode]
            let pageInfo: PageInfo
        }
    }
}
