import Foundation

actor AutomationService {
    struct SetupSession: Decodable, Sendable {
        let id: String
        let setupToken: String
        let authorizationURL: URL
    }

    struct SessionStatus: Decodable, Sendable {
        let state: String
    }

    struct Repository: Decodable, Identifiable, Sendable {
        let id: Int64
        let nameWithOwner: String
    }

    struct Project: Decodable, Identifiable, Sendable {
        let nodeID: String
        let number: Int
        let title: String

        var id: String { nodeID }
    }

    struct StatusOption: Decodable, Identifiable, Sendable {
        let id: String
        let name: String
    }

    struct StatusField: Decodable, Identifiable, Sendable {
        let nodeID: String
        let name: String
        let options: [StatusOption]

        var id: String { nodeID }
    }

    struct SetupOptions: Decodable, Sendable {
        let repositories: [Repository]
        let projects: [Project]
    }

    struct SetupSelection: Encodable, Sendable {
        let sourceRepositoryID: Int64
        let projectNodeID: String
        let projectNumber: Int
        let statusFieldNodeID: String
        let inProgressOptionID: String
        let inReviewOptionID: String
        let doneOptionID: String
    }

    private struct CompletionRequest: Encodable {
        let sourceRepositoryID: Int64
        let projectNodeID: String
        let projectNumber: Int
        let statusFieldNodeID: String
        let inProgressOptionID: String
        let inReviewOptionID: String
        let doneOptionID: String
        let managementToken: String?

        init(selection: SetupSelection, managementToken: String?) {
            sourceRepositoryID = selection.sourceRepositoryID
            projectNodeID = selection.projectNodeID
            projectNumber = selection.projectNumber
            statusFieldNodeID = selection.statusFieldNodeID
            inProgressOptionID = selection.inProgressOptionID
            inReviewOptionID = selection.inReviewOptionID
            doneOptionID = selection.doneOptionID
            self.managementToken = managementToken
        }
    }

    struct DeliveryStatus: Decodable, Sendable {
        let state: String
        let errorCode: String?
        let receivedAt: Date?
    }

    struct Automation: Decodable, Identifiable, Sendable {
        let id: String
        let repositoryNameWithOwner: String
        let projectOwnerLogin: String
        let projectNumber: Int
        let enabled: Bool
        let healthState: String
        let lastDelivery: DeliveryStatus?
    }

    private struct ProjectFieldsRequest: Encodable {
        let projectNodeID: String
        let projectNumber: Int
    }

    private struct ProjectFieldsResponse: Decodable {
        let fields: [StatusField]
    }

    private struct CompletionResponse: Decodable {
        let automationID: String
    }

    private struct AutomationListResponse: Decodable {
        let automations: [Automation]
    }

    private struct AutomationResponse: Decodable {
        let automation: Automation
    }

    private struct AutomationUpdate: Encodable {
        let enabled: Bool
    }

    private struct ServerError: Decodable {
        let error: String
    }

    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder = JSONEncoder()

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    static func configured() -> AutomationService? {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "GitBoardAutomationBaseURL"
        ) as? String,
        let url = URL(string: value),
        url.host != nil,
        url.scheme == "https" || url.host == "localhost" else {
            return nil
        }
        return AutomationService(baseURL: url)
    }

    func createSetupSession(managementToken: String? = nil) async throws -> SetupSession {
        try await send(
            path: "api/setup/sessions",
            method: "POST",
            bearerToken: managementToken
        )
    }

    func sessionStatus(id: String, setupToken: String) async throws -> SessionStatus {
        try await send(path: "api/setup/sessions/\(id)", bearerToken: setupToken)
    }

    func setupOptions(id: String, setupToken: String) async throws -> SetupOptions {
        try await send(path: "api/setup/sessions/\(id)/options", bearerToken: setupToken)
    }

    func statusFields(
        id: String,
        setupToken: String,
        project: Project
    ) async throws -> [StatusField] {
        let response: ProjectFieldsResponse = try await send(
            path: "api/setup/sessions/\(id)/project-fields",
            method: "POST",
            bearerToken: setupToken,
            body: ProjectFieldsRequest(
                projectNodeID: project.nodeID,
                projectNumber: project.number
            )
        )
        return response.fields
    }

    func completeSetup(
        id: String,
        setupToken: String,
        selection: SetupSelection,
        managementToken: String?
    ) async throws -> String {
        let response: CompletionResponse = try await send(
            path: "api/setup/sessions/\(id)/complete",
            method: "POST",
            bearerToken: setupToken,
            body: CompletionRequest(selection: selection, managementToken: managementToken)
        )
        return response.automationID
    }

    func automations(managementToken: String) async throws -> [Automation] {
        let response: AutomationListResponse = try await send(
            path: "api/automations",
            bearerToken: managementToken
        )
        return response.automations
    }

    func setAutomation(
        id: String,
        enabled: Bool,
        managementToken: String
    ) async throws -> Automation {
        let response: AutomationResponse = try await send(
            path: "api/automations/\(id)",
            method: "PATCH",
            bearerToken: managementToken,
            body: AutomationUpdate(enabled: enabled)
        )
        return response.automation
    }

    func deleteAutomation(id: String, managementToken: String) async throws {
        _ = try await perform(
            path: "api/automations/\(id)",
            method: "DELETE",
            bearerToken: managementToken,
            encodedBody: nil
        )
    }

    func beginReauthorization(id: String, managementToken: String) async throws -> SetupSession {
        try await send(
            path: "api/automations/\(id)/reauthorization",
            method: "POST",
            bearerToken: managementToken
        )
    }

    private func send<ResponseBody: Decodable>(
        path: String,
        method: String = "GET",
        bearerToken: String? = nil
    ) async throws -> ResponseBody {
        try await send(
            path: path,
            method: method,
            bearerToken: bearerToken,
            encodedBody: nil
        )
    }

    private func send<ResponseBody: Decodable, RequestBody: Encodable>(
        path: String,
        method: String,
        bearerToken: String? = nil,
        body: RequestBody
    ) async throws -> ResponseBody {
        try await send(
            path: path,
            method: method,
            bearerToken: bearerToken,
            encodedBody: try encoder.encode(body)
        )
    }

    private func send<ResponseBody: Decodable>(
        path: String,
        method: String,
        bearerToken: String?,
        encodedBody: Data?
    ) async throws -> ResponseBody {
        let data = try await perform(
            path: path,
            method: method,
            bearerToken: bearerToken,
            encodedBody: encodedBody
        )
        do {
            return try decoder.decode(ResponseBody.self, from: data)
        } catch {
            throw AutomationServiceError.invalidResponse
        }
    }

    private func perform(
        path: String,
        method: String,
        bearerToken: String?,
        encodedBody: Data?
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.httpBody = encodedBody
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if encodedBody != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AutomationServiceError.invalidResponse
        }
        guard 200..<300 ~= response.statusCode else {
            let code = try? decoder.decode(ServerError.self, from: data).error
            throw AutomationServiceError.server(code ?? "HTTP_\(response.statusCode)")
        }
        return data
    }
}

enum AutomationServiceError: LocalizedError {
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The automation service returned an invalid response."
        case .server(let code):
            return code
        }
    }
}
