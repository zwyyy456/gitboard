import Foundation
import Testing
@testable import GitStride

struct ProjectTableTests {
    @Test func displayPreferencesCopyStoredValuesAndRemoveOnlyTheSelectedView() throws {
        let suite = "GitStrideTests.DisplayPreferences.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let project = ProjectDisplayPreferences(projectID: "P1", viewID: nil)
        let saved = ProjectDisplayPreferences(projectID: "P1", viewID: "saved")
        let other = ProjectDisplayPreferences(projectID: "P1", viewID: "other")
        let values: [String: NSObject] = [
            "columns": NSData(data: Data([1, 2, 3])), "sortColumn": "title" as NSString,
            "sortAscending": false as NSNumber, "fieldID": "priority" as NSString,
            "groupsByStatus": true as NSNumber, "cardFields": "labels,milestone" as NSString
        ]
        for (key, value) in values {
            defaults.set(value, forKey: "projectTable.P1.\(key)")
        }
        project.copy(to: saved, defaults: defaults)
        project.copy(to: other, defaults: defaults)
        for (key, value) in values {
            #expect((defaults.object(forKey: "projectTable.P1.view.saved.\(key)") as? NSObject) == value)
        }
        saved.remove(defaults: defaults)
        for (key, value) in values {
            #expect(defaults.object(forKey: "projectTable.P1.view.saved.\(key)") == nil)
            #expect((defaults.object(forKey: "projectTable.P1.\(key)") as? NSObject) == value)
            #expect((defaults.object(forKey: "projectTable.P1.view.other.\(key)") as? NSObject) == value)
        }
        defaults.removeObject(forKey: project.key(for: .sortAscending))
        project.copy(to: other, defaults: defaults)
        #expect(defaults.object(forKey: other.key(for: .sortAscending)) == nil)
    }

    @Test func groupingPreservesWorkflowOrderMembershipAndWithinGroupSorting() {
        let todo = StatusOption(id: "todo", name: "Todo", color: "GREEN")
        let progress = StatusOption(id: "progress", name: "In Progress", color: "YELLOW")
        let items = [
            item("a", title: "Zulu", status: todo),
            item("b", title: "Alpha", status: progress),
            item("c", title: "Beta", status: todo),
            item("d", title: "No status")
        ]
        let groups = ProjectTableGroup.make(items: items, statuses: [todo, progress],
                                           sortOrder: [ProjectTableSort(column: "title")])
        #expect(groups.map(\.id) == [.status("todo"), .status("progress"), .status(nil)])
        #expect(groups.map { $0.rows.compactMap { $0.item?.id } } == [["c", "a"], ["b"], ["d"]])
        #expect(groups.map { $0.header.count } == [2, 1, 1])
        #expect(groups.allSatisfy { $0.header.id.itemID == nil })

        let projectOrder = ProjectTableGroup.make(items: items, statuses: [todo, progress], sortOrder: [])
        #expect(projectOrder[0].rows.compactMap { $0.item?.id } == ["a", "c"])
        let filtered = ProjectTableGroup.make(items: [items[1]], statuses: [todo, progress], sortOrder: [])
        #expect(filtered.map(\.id) == [.status("progress")])
    }

    @Test func eachCustomColumnSortsItsOwnNumericValuesAndSupportsLegacySelection() {
        var first = item("a", title: "First")
        first.fieldValues = ["estimate": .number(10), "priority": .number(1)]
        var second = item("b", title: "Second")
        second.fieldValues = ["estimate": .number(2), "priority": .number(20)]
        let rows = [first, second].map(ProjectTableRow.init(item:))
        #expect(rows.sorted(using: [ProjectTableSort(column: "field:estimate")]).map(\.id)
                == [.item("b"), .item("a")])
        #expect(rows.sorted(using: [ProjectTableSort(column: "field:priority")]).map(\.id)
                == [.item("a"), .item("b")])
        #expect(rows.sorted(using: [ProjectTableSort(column: "field:estimate", order: .reverse)]).map(\.id)
                == [.item("a"), .item("b")])
        #expect(rows.sorted(using: [ProjectTableSort(column: "field", fieldID: "estimate")]).map(\.id)
                == [.item("b"), .item("a")])
    }

    @Test func workFiltersUseStableIdentityAndDoNotTreatUnknownUserAsEveryone() throws {
        var first = item("a", title: "First")
        first.assignees = [Assignee(login: "Octocat", avatarUrl: "", name: nil)]
        first.milestone = ProjectPlanningReference(id: "m1", title: "v1", repository: "acme/one", number: nil)
        first.parentIssue = ProjectPlanningReference(id: "parent", title: "Ship", repository: "acme/plan", number: 1)
        var second = item("b", title: "Second")
        second.milestone = ProjectPlanningReference(id: "m2", title: "v1", repository: "acme/two", number: nil)
        var filter = ProjectWorkFilter()
        filter.milestoneID = "m1"
        #expect(filter.apply(to: [first, second], currentUserLogin: nil).map(\.id) == ["a"])
        filter.assignedToMe = true
        #expect(filter.apply(to: [first, second], currentUserLogin: nil).isEmpty)
        #expect(filter.apply(to: [first, second], currentUserLogin: "octocat").map(\.id) == ["a"])
        filter.milestoneID = nil
        filter.parentIssueID = "parent"
        #expect(filter.deliveryItems(in: [first, second]).map(\.id) == ["a"])
        filter.statusIDs = ["deleted-status"]
        #expect(filter.apply(to: [first], currentUserLogin: "octocat").isEmpty)

        let view = SavedProjectWorkView(projectID: "project", name: "Delivery", filter: filter,
                                       usesTable: true, hiddenStatusIDs: ["done"])
        let restored = try JSONDecoder().decode(SavedProjectWorkView.self, from: JSONEncoder().encode(view))
        #expect(restored.id == view.id)
        #expect(restored.filter == filter)
        #expect(restored.hiddenStatusIDs == ["done"])
    }

    @Test func blockedFilterExcludesClosedIssuesAndCompletionDoesNotGuessStatusNames() {
        func issue(_ id: String, state: IssueState, blocked: Int, status: String) -> ProjectItem {
            ProjectItem(id: id, contentId: id, contentType: .issue, title: id, number: nil,
                        url: nil, issueState: state, prState: nil, status: status, statusOptionId: nil,
                        assignees: [], engineeringSignals: EngineeringSignals(blockedByCount: blocked))
        }
        let items = [issue("open", state: .open, blocked: 1, status: "Done"),
                     issue("closed", state: .closed, blocked: 1, status: "Todo"),
                     issue("free", state: .open, blocked: 0, status: "Todo")]
        var filter = ProjectWorkFilter()
        filter.completion = .blocked
        #expect(filter.apply(to: items, currentUserLogin: nil).map(\.id) == ["open"])
        filter.completion = .unfinished
        #expect(filter.apply(to: items, currentUserLogin: nil).map(\.id) == ["open", "free"])
        #expect(items.filter(\.isWorkComplete).map(\.id) == ["closed"])
    }

    @Test func prioritySortUsesProjectOptionOrderInsteadOfAlphabeticalLabels() {
        var urgent = item("urgent", title: "Urgent")
        urgent.fieldValues["priority"] = .singleSelect(optionId: "p0", name: "Urgent")
        var low = item("low", title: "Low")
        low.fieldValues["priority"] = .singleSelect(optionId: "p2", name: "Low")
        let unassigned = item("none", title: "None")
        let rows = [low, unassigned, urgent].map(ProjectTableRow.init(item:))
        let sorted = rows.sorted(using: [ProjectTableSort(column: "field:priority", optionOrder: ["p0", "p2"])])
        #expect(sorted.map(\.id) == [.item("urgent"), .item("low"), .item("none")])
    }

    private func item(_ id: String, title: String, status: StatusOption? = nil) -> ProjectItem {
        ProjectItem(id: id, contentId: nil, contentType: .draftIssue, title: title,
                    number: nil, url: nil, issueState: nil, prState: nil,
                    status: status?.name, statusOptionId: status?.id, assignees: [])
    }
}
