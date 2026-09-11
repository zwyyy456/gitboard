import Foundation
import Testing
@testable import GitStride

struct ProjectWorkPreferencesTests {
    @Test func savedViewsKeepTheirOwnLayoutFilterAndDisplayPreferences() throws {
        let suite = "GitStrideTests.WorkPreferences.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ProjectWorkPreferences(defaults: defaults)
        let original = ProjectDisplayPreferences(projectID: "P1", viewID: nil)
        defaults.set(false, forKey: original.key(for: .sortAscending))
        try preferences.setLayout(usesTable: true, projectID: "P1", viewID: nil)
        let view = SavedProjectWorkView(projectID: "P1", name: "Delivery", filter: ProjectWorkFilter(), usesTable: true)
        try preferences.save(view, copyingDisplayFrom: original.id)
        try preferences.setLayout(usesTable: false, projectID: "P1", viewID: view.id)
        try preferences.setHiddenStatuses(["DONE"], viewID: view.id)
        var filter = ProjectWorkFilter()
        filter.milestoneID = "M1"
        try preferences.setFilter(filter, viewID: view.id)

        let loaded = ProjectWorkPreferences(defaults: defaults)
        let restored = try #require(loaded.views.first)
        #expect(restored.id == view.id)
        #expect(!restored.usesTable)
        #expect(restored.filter == filter)
        #expect(restored.hiddenStatusIDs == ["DONE"])
        #expect(loaded.usesTable(projectID: "P1"))
        #expect(!loaded.usesTable(projectID: "P2"))
        let savedDisplay = ProjectDisplayPreferences(projectID: "P1", viewID: view.id)
        #expect(defaults.object(forKey: savedDisplay.key(for: .sortAscending)) as? Bool == false)
        try loaded.delete(viewID: view.id)
        #expect(loaded.views.isEmpty)
        #expect(defaults.object(forKey: savedDisplay.key(for: .sortAscending)) == nil)
        #expect(defaults.object(forKey: original.key(for: .sortAscending)) as? Bool == false)
    }
}
