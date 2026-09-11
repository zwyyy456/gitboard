import Foundation

struct ProjectDisplayPreferences {
    enum Key: String, CaseIterable {
        case columns, sortColumn, sortAscending, fieldID, groupsByStatus, cardFields
    }

    let id: String

    init(id: String) {
        self.id = id
    }

    init(projectID: String, viewID: String?) {
        id = viewID.map { "\(projectID).view.\($0)" } ?? projectID
    }

    func key(for key: Key) -> String {
        "projectTable.\(id).\(key.rawValue)"
    }

    func copy(to destination: Self, defaults: UserDefaults = .standard) {
        for key in Key.allCases {
            defaults.set(defaults.object(forKey: self.key(for: key)), forKey: destination.key(for: key))
        }
    }

    func remove(defaults: UserDefaults = .standard) {
        for key in Key.allCases {
            defaults.removeObject(forKey: self.key(for: key))
        }
    }
}
