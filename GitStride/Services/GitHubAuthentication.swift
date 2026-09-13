import Foundation

enum GitHubAuthenticationMethod: String, Codable, CaseIterable, Sendable {
    case oauth
    #if !APP_STORE
    case cli
    #endif

    var title: String {
        switch self {
        case .oauth: String(localized: "GitHub Login")
        #if !APP_STORE
        case .cli: String(localized: "GitHub CLI")
        #endif
        }
    }
}

struct GitHubDeviceAuthorization: Decodable, Sendable {
    fileprivate let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresIn: Int
    let interval: Int
    private enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code", userCode = "user_code"
        case verificationURL = "verification_uri", expiresIn = "expires_in", interval
    }
}

enum GitHubDeviceAuthorizationProgress: Sendable, Equatable {
    case waitingForAuthorization
    case retrying
    case verifyingAccount
}

protocol GitHubAuthenticating: Sendable {
    func accessToken() async throws -> String
    func rejectAccessToken(_ token: String) async
    func checkActive() async throws
    func invalidate() async
}

actor GitHubAuthentication: GitHubAuthenticating {
    static let clientID = Bundle.main.object(forInfoDictionaryKey: "GitStrideOAuthClientID") as? String ?? ""
    static let scopes = "repo project read:org offline_access"
    nonisolated let method: GitHubAuthenticationMethod
    private let clientID: String
    private let http: any GitHubHTTPClient
    private let keychain: any GitHubCredentialStoring
    private var active: Bool
    private var credential: GitHubOAuthCredential?
    private var didLoadCredential = false
    private var rejectedToken: String?
    private var refreshTask: Task<GitHubOAuthCredential, Error>?
    #if !APP_STORE
    private let runner: any GitHubCommandRunning
    private var cliToken: String?
    private var cliAccount: GitHubAccount?
    #endif

    init(method: GitHubAuthenticationMethod, http: any GitHubHTTPClient,
         clientID: String = GitHubAuthentication.clientID,
         keychain: any GitHubCredentialStoring = GitHubCredentialStore(), restoringSession: Bool = true) {
        self.active = restoringSession
        self.method = method
        self.http = http
        self.clientID = clientID
        self.keychain = keychain
        #if !APP_STORE
        self.runner = ProcessGitHubCommandRunner()
        #endif
    }

    func checkActive() throws {
        try Task.checkCancellation()
        guard active else { throw CancellationError() }
    }

    func invalidate() {
        active = false
        refreshTask?.cancel()
        refreshTask = nil
        credential = nil
        #if !APP_STORE
        cliToken = nil
        #endif
    }

    func deleteCredential() throws {
        if method == .oauth { try keychain.delete() }
    }

    func rejectAccessToken(_ token: String) {
        rejectedToken = token
        #if !APP_STORE
        if cliToken == token { cliToken = nil }
        #endif
    }

    func accessToken() async throws -> String {
        try checkActive()
        #if !APP_STORE
        if method == .cli { return try await loadCLIToken() }
        #endif
        if !didLoadCredential {
            credential = try keychain.load()
            didLoadCredential = true
        }
        guard let credential, credential.clientID == clientID else { throw GitHubError.notAuthenticated }
        if credential.expiresAt > Date().addingTimeInterval(60), rejectedToken != credential.accessToken {
            return credential.accessToken
        }
        if let refreshTask {
            let refreshed = try await refreshTask.value
            try checkActive()
            return refreshed.accessToken
        }
        guard credential.refreshExpiresAt > Date() else { throw GitHubError.notAuthenticated }
        let task = Task { try await self.refresh(credential) }
        refreshTask = task
        defer { refreshTask = nil }
        let refreshed = try await task.value
        try checkActive()
        return refreshed.accessToken
    }

    func beginDeviceAuthorization() async throws -> GitHubDeviceAuthorization {
        try checkActive()
        guard method == .oauth, !clientID.isEmpty, !clientID.contains("$(") else {
            throw GitHubError.oauthUnavailable
        }
        let request = GitHubHTTP.formRequest(url: URL(string: "https://github.com/login/device/code")!,
                                             parameters: ["client_id": clientID, "scope": Self.scopes])
        let (data, response) = try await http.send(request)
        try checkActive()
        try GitHubHTTP.check(response)
        guard let authorization = try? JSONDecoder().decode(GitHubDeviceAuthorization.self, from: data),
              authorization.verificationURL.scheme == "https", authorization.verificationURL.host == "github.com",
              authorization.verificationURL.path == "/login/device", authorization.interval > 0,
              authorization.expiresIn > 0 else { throw GitHubError.oauthUnavailable }
        return authorization
    }

    func completeDeviceAuthorization(
        _ authorization: GitHubDeviceAuthorization,
        onProgress: @Sendable (GitHubDeviceAuthorizationProgress) async throws -> Void
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(authorization.expiresIn))
        var interval = Duration.seconds(authorization.interval)
        try checkActive()
        try await onProgress(.waitingForAuthorization)
        while clock.now < deadline {
            try checkActive()
            try await clock.sleep(until: min(clock.now.advanced(by: interval), deadline))
            try checkActive()
            guard clock.now < deadline else { break }
            let response: TokenResponse
            do {
                response = try await tokenRequest([
                    "client_id": clientID, "device_code": authorization.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                ])
            } catch let error as URLError where error.code == .timedOut {
                try checkActive()
                // RFC 8628 requires a lower polling frequency after a connection timeout.
                interval *= 2
                try await onProgress(.retrying)
                continue
            }
            switch response.error {
            case "authorization_pending":
                try await onProgress(.waitingForAuthorization)
            case "slow_down":
                interval += .seconds(5)
                try await onProgress(.waitingForAuthorization)
            case "access_denied": throw GitHubError.authorizationDenied
            case "expired_token": throw GitHubError.authorizationExpired
            case nil:
                let token = try response.validatedAccessToken()
                try await onProgress(.verifyingAccount)
                try checkActive()
                let account = try await identity(token: token)
                try save(response.credential(clientID: clientID, account: account))
                return
            default: throw GitHubError.oauthUnavailable
            }
        }
        throw GitHubError.authorizationExpired
    }

    private func refresh(_ previous: GitHubOAuthCredential) async throws -> GitHubOAuthCredential {
        let response = try await tokenRequest([
            "client_id": clientID, "grant_type": "refresh_token", "refresh_token": previous.refreshToken
        ])
        guard response.error == nil else { throw GitHubError.notAuthenticated }
        let account = try await identity(token: response.validatedAccessToken())
        guard account.id == previous.account.id else { throw GitHubError.accountChanged }
        let credential = try response.credential(clientID: clientID, account: account)
        try save(credential)
        return credential
    }

    private func save(_ value: GitHubOAuthCredential) throws {
        try checkActive()
        try keychain.save(value)
        credential = value
        didLoadCredential = true
        rejectedToken = nil
    }

    private func tokenRequest(_ parameters: [String: String]) async throws -> TokenResponse {
        let request = GitHubHTTP.formRequest(url: URL(string: "https://github.com/login/oauth/access_token")!, parameters: parameters)
        let (data, response) = try await http.send(request)
        try checkActive()
        try GitHubHTTP.check(response)
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else { throw GitHubError.invalidResponse }
        return decoded
    }

    private func identity(token: String) async throws -> GitHubAccount {
        let (data, response) = try await http.send(GitHubHTTP.request(url: URL(string: "https://api.github.com/user")!, token: token))
        try checkActive()
        try GitHubHTTP.check(response)
        if method == .oauth {
            let scopes = Set((response.value(forHTTPHeaderField: "X-OAuth-Scopes") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            guard scopes.contains("project") else { throw GitHubError.missingProjectScope }
            guard scopes.isSuperset(of: ["repo", "read:org"]) else { throw GitHubError.insufficientPermissions }
        }
        struct Identity: Decodable { let node_id: String; let login: String }
        guard let user = try? JSONDecoder().decode(Identity.self, from: data), !user.node_id.isEmpty else { throw GitHubError.invalidResponse }
        return GitHubAccount(id: user.node_id, login: user.login)
    }

    #if !APP_STORE
    private func loadCLIToken() async throws -> String {
        if let cliToken { return cliToken }
        var arguments = ["auth", "token", "--hostname", "github.com"]
        if let cliAccount { arguments += ["--user", cliAccount.login] }
        let result: GitHubCommandResult
        do { result = try await runner.run(arguments: arguments, standardInput: nil) }
        catch is CancellationError { throw CancellationError() }
        catch GitHubCommandError.executableNotFound { throw GitHubError.ghCLINotFound }
        catch { throw GitHubError.notAuthenticated }
        try checkActive()
        let token = String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isNewline) else { throw GitHubError.notAuthenticated }
        let account = try await identity(token: token)
        if let cliAccount, cliAccount.id != account.id { throw GitHubError.accountChanged }
        cliAccount = account
        cliToken = token
        return token
    }
    #endif

    private struct TokenResponse: Decodable {
        let access_token: String?
        let refresh_token: String?
        let expires_in: Int?
        let refresh_token_expires_in: Int?
        let error: String?

        func validatedAccessToken() throws -> String {
            guard let access_token, !access_token.isEmpty else { throw GitHubError.invalidResponse }
            return access_token
        }

        func credential(clientID: String, account: GitHubAccount) throws -> GitHubOAuthCredential {
            guard let refresh_token, !refresh_token.isEmpty,
                  let expires_in, expires_in > 0,
                  let refresh_token_expires_in, refresh_token_expires_in > 0 else { throw GitHubError.invalidResponse }
            return GitHubOAuthCredential(clientID: clientID, account: account,
                                         accessToken: try validatedAccessToken(), refreshToken: refresh_token,
                                         expiresAt: Date().addingTimeInterval(TimeInterval(expires_in)),
                                         refreshExpiresAt: Date().addingTimeInterval(TimeInterval(refresh_token_expires_in)))
        }
    }
}
