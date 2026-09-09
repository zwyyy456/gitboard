import Foundation

struct ProjectCacheSnapshot: Codable {
    static let currentVersion = 3

    let version: Int
    let accountLogin: String
    let owner: ProjectOwner
    let projects: [Project]
    let detailedProjectIDs: Set<String>
    let selectedProjectId: String?
    let selectedStatusFilter: String?
    let savedAt: Date

    init(
        accountLogin: String,
        owner: ProjectOwner,
        projects: [Project],
        detailedProjectIDs: Set<String>,
        selectedProjectId: String?,
        selectedStatusFilter: String?,
        savedAt: Date = Date()
    ) {
        version = Self.currentVersion
        self.accountLogin = accountLogin
        self.owner = owner
        self.projects = projects
        self.detailedProjectIDs = detailedProjectIDs
        self.selectedProjectId = selectedProjectId
        self.selectedStatusFilter = selectedStatusFilter
        self.savedAt = savedAt
    }
}

enum ProjectCacheError: LocalizedError {
    case applicationSupportUnavailable
    case unsupportedVersion

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "The Application Support directory is unavailable."
        case .unsupportedVersion:
            "The project cache was created by an unsupported version of GitStride."
        }
    }
}

actor ProjectCache {
    private let fileURL: URL?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> ProjectCacheSnapshot? {
        guard let fileURL else { throw ProjectCacheError.applicationSupportUnavailable }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let snapshot = try decoder.decode(ProjectCacheSnapshot.self, from: data)
        guard snapshot.version == ProjectCacheSnapshot.currentVersion else {
            throw ProjectCacheError.unsupportedVersion
        }
        return snapshot
    }

    func save(_ snapshot: ProjectCacheSnapshot) throws {
        guard let fileURL else { throw ProjectCacheError.applicationSupportUnavailable }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    func removeProject(id: String) throws {
        guard let snapshot = try load(), snapshot.projects.contains(where: { $0.id == id }) else { return }
        let remaining = snapshot.projects.filter { $0.id != id }
        try save(ProjectCacheSnapshot(
            accountLogin: snapshot.accountLogin, owner: snapshot.owner,
            projects: remaining, detailedProjectIDs: snapshot.detailedProjectIDs.subtracting([id]),
            selectedProjectId: snapshot.selectedProjectId == id ? remaining.first?.id : snapshot.selectedProjectId,
            selectedStatusFilter: snapshot.selectedProjectId == id ? nil : snapshot.selectedStatusFilter,
            savedAt: snapshot.savedAt
        ))
    }

    private static var defaultFileURL: URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("GitStride", isDirectory: true)
            .appendingPathComponent("project-cache-v2.json")
    }
}
