import Foundation

extension GitHubResponse {
    struct ProjectsPayload: Decodable {
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

    struct ProjectFieldsPayload: Decodable {
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

    struct FieldNode: Decodable {
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

    struct DraftIssuePayload: Decodable {
        let addProjectV2DraftIssue: DraftIssueResult

        struct DraftIssueResult: Decodable {
            let projectItem: ProjectItemResult
        }

        struct ProjectItemResult: Decodable {
            let id: String
        }
    }

    struct AddProjectItemPayload: Decodable {
        let addProjectV2ItemById: Result

        struct Result: Decodable {
            let item: Item
        }

        struct Item: Decodable {
            let id: String
        }
    }

    struct CreateProjectPayload: Decodable {
        let createProjectV2: Result

        struct Result: Decodable {
            let projectV2: ProjectsPayload.ProjectNode
        }
    }

    struct OwnerRepositoriesPayload: Decodable {
        let repositoryOwner: Owner?

        struct Owner: Decodable {
            let repositories: Connection
        }
        struct Connection: Decodable {
            let nodes: [Repository]
            let pageInfo: PageInfo
        }
        struct Repository: Decodable {
            let id: String
            let nameWithOwner: String
        }
    }

    struct LinkProjectRepositoryPayload: Decodable {
        let linkProjectV2ToRepository: Result
        struct Result: Decodable {
            let repository: Repository
        }
        struct Repository: Decodable {
            let id: String
        }
    }

    struct DeleteProjectPayload: Decodable {
        let deleteProjectV2: Result
        struct Result: Decodable {
            let clientMutationId: String?
        }
    }
}
