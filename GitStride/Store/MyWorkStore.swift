import Foundation
import Observation

@MainActor
@Observable
final class MyWorkStore {
    private(set) var followedProjects: [FollowedProject]
    private(set) var filters: [MyWorkFilter]

    init() {
        followedProjects = Self.loadFollowedProjects()
        filters = Self.loadFilters()
    }

    func isFollowing(_ projectID: String) -> Bool {
        followedProjects.contains { $0.id == projectID }
    }

    func activate(accountLogin: String?) {
        guard let accountLogin else { return }
        let defaults = UserDefaults.standard
        if let storedLogin = defaults.string(forKey: "myWorkAccountLogin"),
           storedLogin.caseInsensitiveCompare(accountLogin) != .orderedSame {
            followedProjects = []
            saveFollowedProjects()
        }
        defaults.set(accountLogin, forKey: "myWorkAccountLogin")
    }

    func toggleFollowing(_ project: Project) {
        if let index = followedProjects.firstIndex(where: { $0.id == project.id }) {
            followedProjects.remove(at: index)
            saveFollowedProjects()
        } else {
            let reference = FollowedProject(project: project)
            followedProjects.append(reference)
            saveFollowedProjects()
        }
    }

    func stopFollowing(_ reference: FollowedProject) {
        followedProjects.removeAll { $0.id == reference.id }
        saveFollowedProjects()
    }

    func items(
        for filter: MyWorkFilter,
        in projects: [Project],
        currentUserLogin: String?
    ) -> [MyWorkItem] {
        projects
            .flatMap { project in
                project.items.map { MyWorkItem(project: project, item: $0) }
            }
            .filter { filter.includes($0, currentUserLogin: currentUserLogin) }
            .sorted { $0.updatedDate > $1.updatedDate }
    }

    func attentionCount(in projects: [Project], currentUserLogin: String?) -> Int {
        let filters: [MyWorkFilter] = [.reviewRequested, .ciFailed, .due]
        return Set(filters.flatMap {
            items(for: $0, in: projects, currentUserLogin: currentUserLogin).map(\.id)
        }).count
    }

    func setFilterVisible(_ filter: MyWorkFilter, visible: Bool) {
        if visible {
            guard filters.contains(filter) == false else { return }
            filters.append(filter)
        } else {
            guard filters.count > 1 else { return }
            filters.removeAll { $0 == filter }
        }
        saveFilters()
    }

    func moveFilter(_ filter: MyWorkFilter, offset: Int) {
        guard let index = filters.firstIndex(of: filter) else { return }
        let destination = index + offset
        guard filters.indices.contains(destination) else { return }
        filters.swapAt(index, destination)
        saveFilters()
    }

    func moveFilters(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard offsets.isEmpty == false,
              offsets.allSatisfy({ filters.indices.contains($0) }),
              (0...filters.count).contains(destination) else { return }

        let movedFilters = offsets.map { filters[$0] }
        var reorderedFilters = filters
        for index in offsets.reversed() {
            reorderedFilters.remove(at: index)
        }

        let removedBeforeDestination = offsets.reduce(into: 0) { count, index in
            if index < destination {
                count += 1
            }
        }
        reorderedFilters.insert(
            contentsOf: movedFilters,
            at: destination - removedBeforeDestination
        )

        guard reorderedFilters != filters else { return }
        filters = reorderedFilters
        saveFilters()
    }

    private func saveFollowedProjects() {
        guard let data = try? JSONEncoder().encode(followedProjects) else { return }
        UserDefaults.standard.set(data, forKey: "followedProjects")
    }

    private func saveFilters() {
        UserDefaults.standard.set(filters.map(\.rawValue), forKey: "myWorkFilters")
    }

    private static func loadFollowedProjects() -> [FollowedProject] {
        guard let data = UserDefaults.standard.data(forKey: "followedProjects"),
              let projects = try? JSONDecoder().decode([FollowedProject].self, from: data) else {
            return []
        }
        return projects
    }

    private static func loadFilters() -> [MyWorkFilter] {
        guard let values = UserDefaults.standard.stringArray(forKey: "myWorkFilters") else {
            return MyWorkFilter.allCases
        }
        let filters = values.compactMap(MyWorkFilter.init(rawValue:))
        return filters.isEmpty ? MyWorkFilter.allCases : filters
    }
}
