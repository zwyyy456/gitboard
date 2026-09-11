import Foundation
import Testing
@testable import GitStride

struct ProjectChangeDetectorTests {
    @Test func reportsOnlyMeaningfulTransitionsForExistingItems() {
        let owner = ProjectOwner(id: "U1", login: "octocat", name: nil, kind: .user)
        let item = ProjectItem(
            id: "I1",
            contentId: "C1",
            contentType: .issue,
            title: "Ship release",
            number: 12,
            url: "https://github.com/acme/app/issues/12",
            issueState: .open,
            prState: nil,
            status: "Done",
            statusOptionId: "DONE",
            assignees: [],
            labels: []
        )
        let project = Project(
            id: "P1",
            owner: owner,
            title: "Roadmap",
            number: 1,
            url: "https://github.com/users/octocat/projects/1",
            viewerCanUpdate: true,
            statusField: StatusField(
                id: "STATUS",
                name: "Status",
                options: [StatusOption(id: "DONE", name: "Done", color: "GREEN")]
            ),
            items: [item]
        )
        let previous = [
            "P1:I1": MonitoredItemState(
                projectID: "P1",
                itemID: "I1",
                status: "In progress",
                assignedToCurrentUser: false,
                dueState: .none,
                isBlocked: false
            )
        ]
        let current = [
            "P1:I1": MonitoredItemState(
                projectID: "P1",
                itemID: "I1",
                status: "Done",
                assignedToCurrentUser: true,
                dueState: .overdue,
                isBlocked: true,
                reviewRequested: true,
                checkStatus: .failure
            ),
            "P1:NEW": MonitoredItemState(
                projectID: "P1",
                itemID: "NEW",
                status: "Todo",
                assignedToCurrentUser: true,
                dueState: .none,
                isBlocked: false
            )
        ]

        let changes = ProjectChangeDetector.changes(
            from: previous,
            to: current,
            projects: [project]
        )

        #expect(changes.map(\.kind) == [
            .status(from: "In progress", to: "Done"),
            .assignedToMe,
            .overdue,
            .blocked,
            .reviewRequested,
            .ciFailed
        ])
        #expect(changes.allSatisfy { $0.itemID == "I1" })
        #expect(changes.allSatisfy { $0.statusFieldID == "STATUS" })
        #expect(changes.allSatisfy { $0.doneOptionID == "DONE" })
    }

    @Test func quietHoursCanCrossMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let policy = MonitoringPolicy(interval: .seconds(900), quietStartHour: 22, quietEndHour: 8)
        let late = try Date("2026-08-27T23:00:00Z", strategy: .iso8601)
        let morning = try Date("2026-08-27T07:00:00Z", strategy: .iso8601)
        let noon = try Date("2026-08-27T12:00:00Z", strategy: .iso8601)

        #expect(policy.isQuiet(at: late, calendar: calendar))
        #expect(policy.isQuiet(at: morning, calendar: calendar))
        #expect(policy.isQuiet(at: noon, calendar: calendar) == false)
    }
}

