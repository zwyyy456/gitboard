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

enum ProjectFieldKind: String, Codable, Hashable {
    case singleSelect
    case iteration
    case date
    case number
    case text
    case unsupported
}

struct ProjectFieldOption: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let color: String?
}

struct ProjectIteration: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let startDate: String
    let duration: Int
}

struct ProjectField: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let kind: ProjectFieldKind
    let options: [ProjectFieldOption]
    let iterations: [ProjectIteration]

    var isEditable: Bool {
        kind != .unsupported
    }
}

enum ProjectFieldValue: Codable, Hashable {
    case singleSelect(optionId: String, name: String)
    case iteration(id: String, title: String)
    case date(String)
    case number(Double)
    case text(String)
}

struct Project: Identifiable, Codable, Hashable {
    let id: String
    let owner: ProjectOwner
    let title: String
    let number: Int
    let url: String
    let viewerCanUpdate: Bool
    var fields: [ProjectField]
    var statusField: StatusField?
    var items: [ProjectItem]

    init(
        id: String,
        owner: ProjectOwner,
        title: String,
        number: Int,
        url: String,
        viewerCanUpdate: Bool,
        fields: [ProjectField] = [],
        statusField: StatusField? = nil,
        items: [ProjectItem] = []
    ) {
        self.id = id
        self.owner = owner
        self.title = title
        self.number = number
        self.url = url
        self.viewerCanUpdate = viewerCanUpdate
        self.fields = fields
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

}
