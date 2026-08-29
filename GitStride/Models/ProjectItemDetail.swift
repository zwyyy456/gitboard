import Foundation

struct ProjectItemDetail: Identifiable, Hashable, Sendable {
    let id: String
    let bodyHTML: String
    let author: ItemAuthor?
    let createdAt: String?
    let updatedAt: String?
}

struct ItemAuthor: Hashable, Sendable {
    let login: String
    let avatarURL: String?
}
