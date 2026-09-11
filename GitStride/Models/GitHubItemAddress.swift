import Foundation

struct GitHubItemAddress {
    let owner: String
    let repository: String
    let number: Int
    let command: String

    init?(_ value: String) {
        guard let url = URLComponents(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com" else { return nil }
        let path = url.path.split(separator: "/")
        guard path.count == 4,
              path[2] == "issues" || path[2] == "pull",
              let number = Int(path[3]) else { return nil }
        owner = String(path[0])
        repository = String(path[1])
        self.number = number
        command = path[2] == "pull" ? "pr" : "issue"
    }
}
