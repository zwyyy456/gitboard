import Foundation
import Testing
@testable import GitStride

struct MyWorkFilterTests {
    @Test func smartViewsKeepProjectContextAndApplyStableBoundaries() throws {
        let now = try Date("2026-08-27T00:00:00Z", strategy: .iso8601)
        let owner = ProjectOwner(id: "U1", login: "octocat", name: nil, kind: .user)
        let dueField = ProjectField(
            id: "DUE",
            name: "Due date",
            kind: .date,
            options: [],
            iterations: []
        )
        let item = ProjectItem(
            id: "ITEM",
            contentId: "CONTENT",
            contentType: .issue,
            title: "Blocked delivery",
            number: 7,
            url: "https://github.com/acme/repo/issues/7",
            issueState: .open,
            prState: nil,
            updatedAt: "2026-07-01T00:00:00Z",
            status: "Todo",
            statusOptionId: "TODO",
            assignees: [Assignee(login: "octocat", avatarUrl: "https://example.invalid/avatar", name: nil)],
            labels: [IssueLabel(id: "L1", name: "blocked", color: "ff0000")],
            fieldValues: ["DUE": .date("2026-08-30")]
        )
        let firstProject = Project(
            id: "P1",
            owner: owner,
            title: "First",
            number: 1,
            url: "https://github.com/users/octocat/projects/1",
            viewerCanUpdate: true,
            fields: [dueField],
            items: [item]
        )
        let secondProject = Project(
            id: "P2",
            owner: owner,
            title: "Second",
            number: 2,
            url: "https://github.com/users/octocat/projects/2",
            viewerCanUpdate: true,
            fields: [dueField],
            items: [item]
        )
        let workItem = MyWorkItem(project: firstProject, item: item)

        #expect(MyWorkFilter.assigned.includes(workItem, currentUserLogin: "octocat", now: now))
        #expect(MyWorkFilter.due.includes(workItem, currentUserLogin: nil, now: now))
        #expect(MyWorkFilter.blocked.includes(workItem, currentUserLogin: nil, now: now))
        #expect(MyWorkFilter.stale.includes(workItem, currentUserLogin: nil, now: now))
        #expect(MyWorkFilter.recent.includes(workItem, currentUserLogin: nil, now: now) == false)
        #expect(workItem.id != MyWorkItem(project: secondProject, item: item).id)
    }

    @Test func engineeringViewsUseReviewAndMergeSignals() {
        let owner = ProjectOwner(id: "U1", login: "octocat", name: nil, kind: .user)
        let item = ProjectItem(
            id: "ITEM",
            contentId: "PR",
            contentType: .pullRequest,
            title: "Ready change",
            number: 9,
            url: "https://github.com/acme/app/pull/9",
            issueState: nil,
            prState: .open,
            status: "Review",
            statusOptionId: "REVIEW",
            assignees: [],
            engineeringSignals: EngineeringSignals(
                mergeability: .mergeable,
                reviewDecision: .approved,
                checkStatus: .success,
                reviewRequestedLogins: ["octocat"]
            )
        )
        let project = Project(
            id: "P1",
            owner: owner,
            title: "Work",
            number: 1,
            url: "https://github.com/users/octocat/projects/1",
            viewerCanUpdate: true,
            items: [item]
        )
        let workItem = MyWorkItem(project: project, item: item)

        #expect(MyWorkFilter.reviewRequested.includes(workItem, currentUserLogin: "octocat"))
        #expect(MyWorkFilter.readyToMerge.includes(workItem, currentUserLogin: "octocat"))
        #expect(MyWorkFilter.ciFailed.includes(workItem, currentUserLogin: "octocat") == false)
    }
}
