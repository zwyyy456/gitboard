import Foundation
import Testing
@testable import GitStride

actor TestGitHubCredentials: GitHubAuthenticating {
    private var active = true
    func accessToken() throws -> String { try checkActive(); return "test-token" }
    func checkActive() throws { if !active { throw CancellationError() }; try Task.checkCancellation() }
    func rejectAccessToken(_ token: String) {}
    func invalidate() { active = false }
}

extension GitHubService {
    init(http: any GitHubHTTPClient) {
        self.init(http: http, credentials: TestGitHubCredentials())
    }
}

extension URLRequest {
    var graphQLQuery: String? {
        guard let httpBody, let json = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any] else { return nil }
        return json["query"] as? String
    }
    func hasVariable(_ key: String, _ value: String) -> Bool {
        guard let httpBody, let json = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
              let variables = json["variables"] as? [String: Any] else { return false }
        return variables[key] as? String == value
    }
}

actor FixtureGitHubHTTPClient: GitHubHTTPClient {
    private var responses: [Data]
    private var calls: [URLRequest] = []
    private let status: Int
    private let headers: [String: String]

    init(responses: [String], status: Int = 200, headers: [String: String] = [:]) {
        self.responses = responses.map { Data($0.utf8) }
        self.status = status
        self.headers = headers
    }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        calls.append(request)
        guard !responses.isEmpty else { throw FixtureError.missingResponse }
        return (responses.removeFirst(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
    func cancel() {}
    func recordedBodies() -> [Data?] { calls.map(\.httpBody) }
    func recordedRequests() -> [URLRequest] { calls }
    private enum FixtureError: Error { case missingResponse }
}

enum SuspendingHTTPStep: Sendable {
    case response(String)
    case suspended(String, String)
    case failure(URLError.Code)
    case cancelled
}

actor SuspendingGitHubHTTPClient: GitHubHTTPClient {
    private let headers: [String: String]
    private var steps: [SuspendingHTTPStep]
    private var calls: [URLRequest] = []
    private var suspendedIDs: Set<String> = []
    private var resultWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var suspensionWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(steps: [SuspendingHTTPStep], headers: [String: String] = [:]) { self.steps = steps; self.headers = headers }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !steps.isEmpty else { throw FixtureError.missingResponse }
        calls.append(request)
        let body: String
        switch steps.removeFirst() {
        case .failure(let code): throw URLError(code)
        case .cancelled: throw CancellationError()
        case .response(let response): body = response
        case .suspended(let id, let response):
            body = response
            suspendedIDs.insert(id)
            suspensionWaiters.removeValue(forKey: id)?.forEach { $0.resume() }
            await withCheckedContinuation { resultWaiters[id] = $0 }
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
    func cancel() {}
    func waitUntilSuspended(_ id: String) async {
        if suspendedIDs.contains(id) { return }
        await withCheckedContinuation { suspensionWaiters[id, default: []].append($0) }
    }
    func release(_ id: String) { resultWaiters.removeValue(forKey: id)?.resume() }
    func recordedRequests() -> [URLRequest] { calls }
    func recordedBodies() -> [Data?] { calls.map(\.httpBody) }
    func recordedCallCount() -> Int { calls.count }
    private enum FixtureError: Error { case missingResponse }
}
