import Foundation

enum ProjectOwnerKind: String, Codable, Hashable {
    case user
    case organization
}

struct ProjectOwner: Identifiable, Codable, Hashable {
    let id: String
    let login: String
    let name: String?
    let kind: ProjectOwnerKind
}

struct Project: Identifiable, Codable, Hashable {
    let id: String
    let owner: ProjectOwner
    let title: String
    let number: Int
    let url: String
    let viewerCanUpdate: Bool
    var statusField: StatusField?
    var items: [ProjectItem]

    init(
        id: String,
        owner: ProjectOwner,
        title: String,
        number: Int,
        url: String,
        viewerCanUpdate: Bool,
        statusField: StatusField? = nil,
        items: [ProjectItem] = []
    ) {
        self.id = id
        self.owner = owner
        self.title = title
        self.number = number
        self.url = url
        self.viewerCanUpdate = viewerCanUpdate
        self.statusField = statusField
        self.items = items
    }

    static func == (lhs: Project, rhs: Project) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var statusOptions: [StatusOption] {
        statusField?.options ?? []
    }

    func items(forStatus status: String?) -> [ProjectItem] {
        items.filter { $0.status == status }
    }

    func itemCount(forStatus status: String) -> Int {
        items.filter { $0.status == status }.count
    }

    var noStatusItems: [ProjectItem] {
        items.filter { $0.status == nil }
    }

    var statusCounts: [(status: StatusOption, count: Int)] {
        statusOptions.map { option in
            (option, itemCount(forStatus: option.name))
        }
    }
}

struct UserSearchResponse: Codable {
    let data: DataContainer

    struct DataContainer: Codable {
        let search: SearchConnection
    }

    struct SearchConnection: Codable {
        let nodes: [UserNode]
    }

    struct UserNode: Codable {
        let login: String?
        let avatarUrl: String?
        let name: String?
    }
}

struct GetUserResponse: Codable {
    let data: DataContainer

    struct DataContainer: Codable {
        let user: UserNode?
    }

    struct UserNode: Codable {
        let id: String
        let login: String
        let avatarUrl: String
        let name: String?
    }
}
