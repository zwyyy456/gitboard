import Foundation
import os
import Testing
@testable import GitStride

private struct MemoryGitHubCredentials: GitHubCredentialStoring {
    let value: OSAllocatedUnfairLock<GitHubOAuthCredential?>
    init(_ credential: GitHubOAuthCredential?) { value = OSAllocatedUnfairLock(initialState: credential) }
    func load() -> GitHubOAuthCredential? { value.withLock { $0 } }
    func save(_ credential: GitHubOAuthCredential) { value.withLock { $0 = credential } }
    func delete() { value.withLock { $0 = nil } }
}

struct GitHubAuthenticationTests {
    private let account = GitHubAccount(id: "USER", login: "example")
    private static let refreshed = #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":28800,"refresh_token_expires_in":15897600}"#
    private static let identity = #"{"node_id":"USER","login":"example"}"#
    private static let headers = ["X-OAuth-Scopes": "project, repo, read:org"]

    private func expiredCredential() -> GitHubOAuthCredential {
        GitHubOAuthCredential(clientID: "public-client", account: account, accessToken: "old-access",
                              refreshToken: "old-refresh", expiresAt: .distantPast, refreshExpiresAt: .distantFuture)
    }

    private func deviceAuthorization(expiresIn: Int = 60) throws -> GitHubDeviceAuthorization {
        let data = Data("""
        {"device_code":"device","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":\(expiresIn),"interval":1}
        """.utf8)
        return try JSONDecoder().decode(GitHubDeviceAuthorization.self, from: data)
    }

    @Test(.timeLimit(.minutes(1)))
    func timedOutPollingBacksOffAndReportsAccountVerification() async throws {
        let keychain = MemoryGitHubCredentials(nil)
        let http = SuspendingGitHubHTTPClient(steps: [
            .failure(.timedOut), .response(Self.refreshed), .response(Self.identity)
        ], headers: Self.headers)
        let auth = GitHubAuthentication(method: .oauth, http: http, clientID: "public-client", keychain: keychain)
        let events = OSAllocatedUnfairLock(initialState: [(GitHubDeviceAuthorizationProgress, ContinuousClock.Instant)]())

        try await auth.completeDeviceAuthorization(deviceAuthorization()) { progress in
            events.withLock { $0.append((progress, .now)) }
        }

        let recorded = events.withLock { $0 }
        #expect(recorded.map(\.0) == [.waitingForAuthorization, .retrying, .verifyingAccount])
        try #require(recorded.count == 3)
        #expect(recorded[1].1.duration(to: recorded[2].1) >= .seconds(2))
        #expect(keychain.load()?.accessToken == "new-access")
    }

    @Test(.timeLimit(.minutes(1)))
    func pollingBackoffStopsAtDeviceCodeExpiry() async throws {
        let keychain = MemoryGitHubCredentials(nil)
        let http = SuspendingGitHubHTTPClient(steps: [.failure(.timedOut)])
        let auth = GitHubAuthentication(method: .oauth, http: http, clientID: "public-client", keychain: keychain)
        await #expect(throws: GitHubError.authorizationExpired) {
            try await auth.completeDeviceAuthorization(deviceAuthorization(expiresIn: 2)) { _ in }
        }
        #expect(await http.recordedCallCount() == 1)
        #expect(keychain.load() == nil)
    }

    @Test(arguments: GitHubAuthenticationMethod.allCases)
    func disconnectedLaunchDoesNotRestoreAnyCredential(_ method: GitHubAuthenticationMethod) async throws {
        let http = FixtureGitHubHTTPClient(responses: [])
        let auth = GitHubAuthentication(method: method, http: http, clientID: "public-client",
                                        keychain: MemoryGitHubCredentials(expiredCredential()), initialState: .signedOut)
        await #expect(throws: CancellationError.self) { try await auth.accessToken() }
        #expect(await http.recordedRequests().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func signingInIgnoresStoredCredentialsUntilAuthorizationSucceeds() async throws {
        let keychain = MemoryGitHubCredentials(expiredCredential())
        let http = FixtureGitHubHTTPClient(responses: [Self.refreshed, Self.identity], headers: Self.headers)
        let auth = GitHubAuthentication(method: .oauth, http: http, clientID: "public-client",
                                        keychain: keychain, initialState: .signingIn)

        await #expect(throws: GitHubError.notAuthenticated) { try await auth.accessToken() }
        #expect(await http.recordedRequests().isEmpty)
        #expect(keychain.load()?.accessToken == "old-access")

        try await auth.completeDeviceAuthorization(deviceAuthorization()) { _ in }

        #expect(try await auth.accessToken() == "new-access")
        #expect(keychain.load()?.refreshToken == "new-refresh")
    }

    @Test(.timeLimit(.minutes(1)))
    func deniedSignInPreservesStoredCredentialsWithoutUsingThem() async throws {
        let keychain = MemoryGitHubCredentials(expiredCredential())
        let http = FixtureGitHubHTTPClient(responses: [#"{"error":"access_denied"}"#])
        let auth = GitHubAuthentication(method: .oauth, http: http, clientID: "public-client",
                                        keychain: keychain, initialState: .signingIn)

        await #expect(throws: GitHubError.authorizationDenied) {
            try await auth.completeDeviceAuthorization(deviceAuthorization()) { _ in }
        }

        #expect(keychain.load()?.accessToken == "old-access")
        await #expect(throws: GitHubError.notAuthenticated) { try await auth.accessToken() }
        #expect(await http.recordedRequests().count == 1)
    }

    @Test func concurrentRequestsShareRefreshAndPersistTheRotatedPair() async throws {
        let keychain = MemoryGitHubCredentials(expiredCredential())
        let http = SuspendingGitHubHTTPClient(steps: [.suspended("refresh", Self.refreshed), .response(Self.identity)], headers: Self.headers)
        let auth = GitHubAuthentication(method: .oauth, http: http, clientID: "public-client", keychain: keychain)
        let first = Task { try await auth.accessToken() }
        await http.waitUntilSuspended("refresh")
        let second = Task { try await auth.accessToken() }
        await http.release("refresh")
        #expect(try await first.value == "new-access")
        #expect(try await second.value == "new-access")
        #expect(keychain.load()?.refreshToken == "new-refresh")
        let requests = await http.recordedRequests()
        #expect(requests.count == 2)
        let body = String(decoding: try #require(requests.first?.httpBody), as: UTF8.self)
        #expect(body.contains("grant_type=refresh_token"))
        #expect(!body.contains("client_secret"))
    }

    @Test func disconnectDuringRefreshCannotRestoreCredentials() async throws {
        let keychain = MemoryGitHubCredentials(expiredCredential())
        let http = SuspendingGitHubHTTPClient(steps: [.suspended("refresh", Self.refreshed)], headers: Self.headers)
        let auth = GitHubAuthentication(method: .oauth, http: http, clientID: "public-client", keychain: keychain)
        let request = Task { try await auth.accessToken() }
        await http.waitUntilSuspended("refresh")
        await auth.invalidate()
        try await auth.deleteCredential()
        await http.release("refresh")
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(keychain.load() == nil)
        #expect(await http.recordedCallCount() == 1)
    }

    @Test func mismatchedRefreshIdentityIsNotStored() async throws {
        let keychain = MemoryGitHubCredentials(expiredCredential())
        let http = FixtureGitHubHTTPClient(responses: [Self.refreshed, #"{"node_id":"OTHER","login":"other"}"#], headers: Self.headers)
        let auth = GitHubAuthentication(method: .oauth, http: http, clientID: "public-client", keychain: keychain)
        await #expect(throws: GitHubError.accountChanged) { try await auth.accessToken() }
        #expect(keychain.load()?.account.id == "USER")
        #expect(keychain.load()?.accessToken == "old-access")
    }

    @Test func rejectsAnUnexpectedDeviceAuthorizationDestination() async throws {
        let http = FixtureGitHubHTTPClient(responses: [#"{"device_code":"device","user_code":"ABCD-EFGH","verification_uri":"https://example.com/login/device","expires_in":900,"interval":5}"#])
        let auth = GitHubAuthentication(method: .oauth, http: http, clientID: "public-client", keychain: MemoryGitHubCredentials(nil))
        await #expect(throws: GitHubError.oauthUnavailable) { try await auth.beginDeviceAuthorization() }
    }

    @Test func invalidatedSessionCannotContinuePagination() async throws {
        let response = #"{"data":{"repositoryOwner":{"repositories":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":"next"}}}}}"#
        let http = SuspendingGitHubHTTPClient(steps: [.suspended("read", response)])
        let service = GitHubService(http: http)
        let request = Task { try await service.fetchRepositories(owner: ProjectOwner(id: "USER", login: "example", name: nil, kind: .user)) }
        await http.waitUntilSuspended("read")
        await service.invalidate()
        await http.release("read")
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await http.recordedCallCount() == 1)
    }

    @Test func rejectedMutationIsNotAutomaticallyResubmitted() async throws {
        let http = FixtureGitHubHTTPClient(responses: ["{}"], status: 401)
        await #expect(throws: GitHubError.notAuthenticated) { try await GitHubService(http: http).deleteProject(id: "PROJECT") }
        #expect(await http.recordedRequests().count == 1)
    }

    @Test func restLabelEditsPreserveNamesAndEncodePathSeparators() async throws {
        let http = FixtureGitHubHTTPClient(responses: ["{}", "{}"])
        let service = GitHubService(http: http)
        let name = "a/b # + 中文"
        let url = "https://github.com/example/repo/pull/42"
        try await service.addLabel(issueUrl: url, label: name)
        try await service.removeLabel(issueUrl: url, label: name)
        let requests = await http.recordedRequests()
        let body = try JSONDecoder().decode([String: [String]].self, from: #require(requests[0].httpBody))
        #expect(body["labels"] == [name])
        #expect(requests[0].url?.path == "/repos/example/repo/issues/42/labels")
        #expect(requests[1].httpMethod == "DELETE")
        #expect(requests[1].url?.absoluteString.contains("a%2Fb%20%23%20%2B%20") == true)
    }
}
