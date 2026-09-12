import Foundation
import Testing
@testable import GitStride

struct ProjectCacheTests {
    @Test func deletionRemovesOnlyTheTargetAndClearsTheLastSelection() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DeleteCache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = ProjectCache(fileURL: url)
        let owner = ProjectOwner(id: "U", login: "me", name: nil, kind: .user)
        let projects = ["P1", "P2"].map {
            Project(id: $0, owner: owner, title: $0, number: 1, url: "", viewerCanUpdate: true)
        }
        try await cache.save(ProjectCacheSnapshot(
            accountLogin: "me", owner: owner, projects: projects,
            detailedProjectIDs: ["P1", "P2"], selectedProjectId: "P1", selectedStatusFilter: "Todo"
        ))
        try await cache.removeProject(id: "P1")
        let remaining = try #require(try await cache.load())
        #expect(remaining.projects.map(\.id) == ["P2"])
        #expect(remaining.detailedProjectIDs == ["P2"])
        #expect(remaining.selectedProjectId == "P2")
        #expect(remaining.selectedStatusFilter == nil)
        try await cache.removeProject(id: "P2")
        let empty = try #require(try await cache.load())
        #expect(empty.projects.isEmpty)
        #expect(empty.selectedProjectId == nil)
    }

    @Test func roundTripPreservesTheDomainSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitStrideTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let owner = ProjectOwner(id: "U1", login: "octocat", name: "Octocat", kind: .user)
        let field = ProjectField(
            id: "F1",
            name: "Priority",
            kind: .singleSelect,
            options: [ProjectFieldOption(id: "HIGH", name: "High", color: "RED")],
            iterations: []
        )
        let item = ProjectItem(
            id: "I1",
            contentId: "C1",
            contentType: .issue,
            title: "Cached issue",
            number: 42,
            url: "https://github.com/acme/repo/issues/42",
            issueState: .open,
            prState: nil,
            status: "Todo",
            statusOptionId: "TODO",
            assignees: [],
            fieldValues: ["F1": .singleSelect(optionId: "HIGH", name: "High")]
        )
        let project = Project(
            id: "P1",
            owner: owner,
            title: "Work",
            number: 1,
            url: "https://github.com/users/octocat/projects/1",
            viewerCanUpdate: true,
            linkedRepositories: ["acme/repo"],
            fields: [field],
            items: [item]
        )
        let cache = ProjectCache(fileURL: directory.appendingPathComponent("cache.json"))

        try await cache.save(
            ProjectCacheSnapshot(
                accountLogin: "octocat",
                owner: owner,
                projects: [project],
                detailedProjectIDs: ["P1"],
                selectedProjectId: "P1",
                selectedStatusFilter: "Todo"
            )
        )
        let loaded = try #require(try await cache.load())

        #expect(loaded.version == ProjectCacheSnapshot.currentVersion)
        #expect(loaded.accountLogin == "octocat")
        #expect(loaded.projects.first?.linkedRepositories == ["acme/repo"])
        #expect(loaded.detailedProjectIDs == ["P1"])
        #expect(loaded.projects.first?.items.first?.title == "Cached issue")
        #expect(loaded.projects.first?.items.first?.fieldValues["F1"] == .singleSelect(optionId: "HIGH", name: "High"))
    }
}
