import Foundation

struct QuickCreateRequest: Equatable, Sendable {
    let title: String
    let repository: String?
    let status: String?
    let priority: String?
    let labels: [String]
    let assignees: [String]
}

enum QuickCreateParser {
    static func parse(_ input: String) -> QuickCreateRequest {
        var title: [Substring] = []
        var repository: String?
        var status: String?
        var priority: String?
        var labels: [String] = []
        var assignees: [String] = []

        for token in input.split(whereSeparator: \Character.isWhitespace) {
            let value = String(token)
            if value.hasPrefix("repo:"), value.count > 5 {
                repository = String(value.dropFirst(5))
            } else if value.hasPrefix("status:"), value.count > 7 {
                status = String(value.dropFirst(7))
            } else if value.hasPrefix("priority:"), value.count > 9 {
                priority = String(value.dropFirst(9))
            } else if value.hasPrefix("#"), value.count > 1 {
                labels.append(String(value.dropFirst()))
            } else if value.hasPrefix("@"), value.count > 1 {
                assignees.append(String(value.dropFirst()))
            } else if value != ">" {
                title.append(token)
            }
        }

        return QuickCreateRequest(
            title: title.joined(separator: " "),
            repository: repository,
            status: status,
            priority: priority,
            labels: labels,
            assignees: assignees
        )
    }
}
