import Foundation

struct ProjectCacheSnapshot: Codable {
    static let currentVersion = 2

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

enum ProjectCacheError: Error {
    case unsupportedVersion
}

actor ProjectCache {
    private let fileURL: URL
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
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let snapshot = try decoder.decode(ProjectCacheSnapshot.self, from: data)
        guard snapshot.version == ProjectCacheSnapshot.currentVersion else {
            throw ProjectCacheError.unsupportedVersion
        }
        return snapshot
    }

    func save(_ snapshot: ProjectCacheSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    private static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("GitBoard", isDirectory: true)
            .appendingPathComponent("project-cache-v2.json")
    }
}
