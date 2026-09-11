import SwiftUI

struct ProjectWorkPreferences: DynamicProperty {
    @AppStorage private var layoutsData: Data
    @AppStorage private var viewsData: Data
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _layoutsData = AppStorage(wrappedValue: Data(), "projectTableLayouts", store: defaults)
        _viewsData = AppStorage(wrappedValue: Data(), "savedProjectWorkViews", store: defaults)
    }

    var views: [SavedProjectWorkView] {
        (try? JSONDecoder().decode([SavedProjectWorkView].self, from: viewsData)) ?? []
    }

    private var tableProjectIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: layoutsData)) ?? []
    }

    func usesTable(projectID: String) -> Bool {
        tableProjectIDs.contains(projectID)
    }

    func setLayout(usesTable: Bool, projectID: String, viewID: String?) throws {
        if let viewID {
            try update(viewID) { $0.usesTable = usesTable }
        } else {
            var ids = tableProjectIDs
            if usesTable { ids.insert(projectID) } else { ids.remove(projectID) }
            layoutsData = try JSONEncoder().encode(ids)
        }
    }

    func setHiddenStatuses(_ ids: Set<String>, viewID: String) throws {
        try update(viewID) { $0.hiddenStatusIDs = ids }
    }

    func setFilter(_ filter: ProjectWorkFilter, viewID: String) throws {
        try update(viewID) { $0.filter = filter }
    }

    func save(_ view: SavedProjectWorkView, copyingDisplayFrom sourceID: String) throws {
        let data = try JSONEncoder().encode(views + [view])
        ProjectDisplayPreferences(id: sourceID).copy(
            to: ProjectDisplayPreferences(projectID: view.projectID, viewID: view.id), defaults: defaults
        )
        viewsData = data
    }

    func delete(viewID: String) throws {
        guard let view = views.first(where: { $0.id == viewID }) else { return }
        let data = try JSONEncoder().encode(views.filter { $0.id != viewID })
        ProjectDisplayPreferences(projectID: view.projectID, viewID: viewID).remove(defaults: defaults)
        viewsData = data
    }

    private func update(_ viewID: String, change: (inout SavedProjectWorkView) -> Void) throws {
        var values = views
        guard let index = values.firstIndex(where: { $0.id == viewID }) else { return }
        change(&values[index])
        viewsData = try JSONEncoder().encode(values)
    }
}
