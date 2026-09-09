import Foundation
import Testing
@testable import GitStride

struct ProjectTableTests {
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

    private func item(_ id: String, title: String, status: StatusOption? = nil) -> ProjectItem {
        ProjectItem(id: id, contentId: nil, contentType: .draftIssue, title: title,
                    number: nil, url: nil, issueState: nil, prState: nil,
                    status: status?.name, statusOptionId: status?.id, assignees: [])
    }
}
