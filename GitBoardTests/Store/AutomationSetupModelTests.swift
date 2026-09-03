import Foundation
import Testing
@testable import GitBoard

@MainActor
struct AutomationSetupModelTests {
    @Test func unavailableServiceWinsSavedToken() {
        let model = AutomationSetupModel(
            service: nil,
            tokenStore: StubManagementTokenStore(token: "saved-token")
        )

        #expect(model.phase == .unavailable)
    }

    @Test func savedTokenStartsConnectionLoad() {
        let model = AutomationSetupModel(
            service: AutomationService(baseURL: URL(string: "https://example.invalid")!),
            tokenStore: StubManagementTokenStore(token: "saved-token")
        )

        #expect(model.phase == .loadingConnection)
    }

    @Test func savesManagementTokenBeforeCompletingInitialSetup() async throws {
        let recorder = EventRecorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AutomationURLProtocol.self]
        AutomationURLProtocol.handler = { request in
            let path = request.url?.path
            switch (request.httpMethod, path) {
            case ("POST", "/api/setup/sessions"):
                return response(request, status: 201, body: """
                    {"id":"setup","setupToken":"setup-token","authorizationURL":"https://example.invalid/setup/setup/oauth","expiresAt":"2099-01-01T00:00:00Z"}
                    """)
            case ("GET", "/api/setup/sessions/setup"):
                return response(request, body: """
                    {"id":"setup","state":"CONFIGURATION_PENDING","expiresAt":"2099-01-01T00:00:00Z"}
                    """)
            case ("GET", "/api/setup/sessions/setup/options"):
                return response(request, body: """
                    {"repositories":[{"id":11,"nameWithOwner":"owner/repository"}],"projects":[{"nodeID":"PROJECT","number":1,"title":"Board"}]}
                    """)
            case ("POST", "/api/setup/sessions/setup/project-fields"):
                return response(request, body: """
                    {"fields":[{"nodeID":"FIELD","name":"Status","options":[{"id":"PROGRESS","name":"In Progress"},{"id":"REVIEW","name":"In Review"},{"id":"DONE","name":"Done"}]}]}
                    """)
            case ("POST", "/api/setup/sessions/setup/complete"):
                recorder.record("complete")
                return response(request, body: "{\"automationID\":\"automation\"}")
            case ("GET", "/api/automations"):
                return response(request, body: "{\"automations\":[]}")
            default:
                throw AutomationServiceError.invalidResponse
            }
        }
        defer { AutomationURLProtocol.handler = nil }

        let service = AutomationService(
            baseURL: URL(string: "https://example.invalid")!,
            session: URLSession(configuration: configuration)
        )
        let model = AutomationSetupModel(
            service: service,
            tokenStore: RecordingManagementTokenStore(recorder: recorder),
            makeManagementToken: { "fixed-management-token" }
        )

        _ = await model.startSetup()
        await model.observeSetup()
        model.inProgressOptionID = "PROGRESS"
        model.inReviewOptionID = "REVIEW"
        model.doneOptionID = "DONE"
        await model.completeSetup()

        #expect(recorder.snapshot() == [
            "save:fixed-management-token",
            "complete",
        ])
        #expect(model.phase == .connected)
    }
}

private struct StubManagementTokenStore: ManagementTokenStoring {
    let token: String?

    func load() throws -> String? { token }
    func save(_ token: String) throws {}
    func delete() throws {}
}

private struct RecordingManagementTokenStore: ManagementTokenStoring {
    let recorder: EventRecorder

    func load() throws -> String? { recorder.savedToken() }
    func save(_ token: String) throws { recorder.save(token) }
    func delete() throws {}
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var token: String?

    func save(_ token: String) {
        lock.withLock {
            self.token = token
            events.append("save:\(token)")
        }
    }

    func record(_ event: String) {
        lock.withLock { events.append(event) }
    }

    func savedToken() -> String? {
        lock.withLock { token }
    }

    func snapshot() -> [String] {
        lock.withLock { events }
    }
}

private final class AutomationURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw AutomationServiceError.invalidResponse
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func response(
    _ request: URLRequest,
    status: Int = 200,
    body: String
) -> (HTTPURLResponse, Data) {
    (
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!,
        Data(body.utf8)
    )
}
