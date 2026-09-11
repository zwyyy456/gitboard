import Foundation

enum GitHubResponse {
    struct GraphQLEnvelope<Payload: Decodable>: Decodable {
        let data: Payload?
    }

    struct GraphQLIssue: Decodable {
        let message: String
    }

    struct EmptyPayload: Decodable {}

    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct SessionPayload: Decodable {
        let viewer: Viewer

        struct Viewer: Decodable {
            let id: String
            let login: String
        }
    }

    struct OwnersPayload: Decodable {
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

    struct GraphQLErrorResponse: Decodable {
        let errors: [GraphQLIssue]?
    }

    struct UserSearchPayload: Decodable {
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
}
