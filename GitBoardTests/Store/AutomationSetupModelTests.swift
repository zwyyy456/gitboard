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
        let baseURL = URL(string: "https://initial-setup.invalid")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AutomationURLProtocol.self]
        AutomationURLProtocol.register(host: baseURL.host!) { request in
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
                    {"projects":[{"nodeID":"PROJECT","number":1,"title":"Board"}]}
                    """)
            case ("POST", "/api/setup/sessions/setup/project-fields"):
                return response(request, body: """
                    {"fields":[{"nodeID":"FIELD","name":"Status","options":[{"id":"PROGRESS","name":"In Progress"},{"id":"REVIEW","name":"In Review"},{"id":"DONE","name":"Done"}]}]}
                    """)
            case ("POST", "/api/setup/sessions/setup/complete"):
                let body = try requestBody(request)
                let object = try #require(
                    try JSONSerialization.jsonObject(with: body)
                        as? [String: Any]
                )
                recorder.record("policy:\(object["reviewStatusPolicy"] as? String ?? "missing")")
                recorder.record("legacy-review:\(object["inReviewOptionID"] == nil)")
                recorder.record("complete")
                return response(request, body: "{\"automationID\":\"automation\"}")
            case ("GET", "/api/automations"):
                return response(request, body: "{\"automations\":[]}")
            default:
                throw AutomationServiceError.invalidResponse
            }
        }
        defer { AutomationURLProtocol.unregister(host: baseURL.host!) }

        let service = AutomationService(
            baseURL: baseURL,
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
        model.doneOptionID = "DONE"
        #expect(model.canComplete)
        await model.completeSetup()

        #expect(recorder.snapshot() == [
            "save:fixed-management-token",
            "policy:ENSURE_IN_REVIEW",
            "legacy-review:true",
            "complete",
        ])
        #expect(model.phase == .connected)
    }

    @Test func reloadsAutomationBeforeEndingCompletedReauthorizationSession() async throws {
        let recorder = EventRecorder()
        let baseURL = URL(string: "https://reauthorization.invalid")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AutomationURLProtocol.self]
        AutomationURLProtocol.register(host: baseURL.host!) { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/automations"):
                recorder.record("automations")
                return response(request, body: """
                    {"automations":[{"id":"automation","accountLogin":"owner","repositoryCount":2,"mappingProjectNumber":8,"enabled":true,"healthState":"CONTENT_VISIBILITY_UNVERIFIED","lastDelivery":null}]}
                    """)
            case ("POST", "/api/automations/automation/reauthorization"):
                return response(request, status: 201, body: """
                    {"id":"reauthorization","setupToken":"setup-token","authorizationURL":"https://example.invalid/setup/reauthorization/oauth","expiresAt":"2099-01-01T00:00:00Z"}
                    """)
            case ("GET", "/api/setup/sessions/reauthorization"):
                return response(request, body: """
                    {"id":"reauthorization","state":"COMPLETE","expiresAt":"2099-01-01T00:00:00Z"}
                    """)
            default:
                throw AutomationServiceError.invalidResponse
            }
        }
        defer { AutomationURLProtocol.unregister(host: baseURL.host!) }

        let service = AutomationService(
            baseURL: baseURL,
            session: URLSession(configuration: configuration)
        )
        let model = AutomationSetupModel(
            service: service,
            tokenStore: StubManagementTokenStore(token: "saved-token")
        )

        await model.loadConnection()
        _ = await model.reauthorizeAutomation(id: "automation")
        recorder.clear()
        withObservationTracking {
            _ = model.setupSessionID
        } onChange: {
            recorder.record("session-ended")
        }

        await model.observeSetup()

        #expect(recorder.snapshot() == ["automations", "session-ended"])
        #expect(model.phase == .connected)
        #expect(model.automations.first?.healthState == "CONTENT_VISIBILITY_UNVERIFIED")
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

    func clear() {
        lock.withLock { events.removeAll() }
    }
}

private final class AutomationURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(host: String, handler: @escaping Handler) {
        lock.withLock { handlers[host] = handler }
    }

    static func unregister(host: String) {
        _ = lock.withLock { handlers.removeValue(forKey: host) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let host = request.url?.host,
                  let handler = Self.lock.withLock({ Self.handlers[host] }) else {
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

private func requestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else {
        throw AutomationServiceError.invalidResponse
    }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? AutomationServiceError.invalidResponse }
        if count == 0 { return result }
        result.append(buffer, count: count)
    }
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
