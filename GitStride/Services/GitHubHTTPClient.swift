import Foundation

protocol GitHubHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func cancel() async
}

extension URLSession: GitHubHTTPClient {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        return (data, response)
    }

    func cancel() async { invalidateAndCancel() }

    static func gitHubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }
}

enum GitHubHTTP {
    static func request(url: URL, method: String = "GET", token: String? = nil, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("GitStride", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    static func formRequest(url: URL, parameters: [String: String]) -> URLRequest {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = parameters.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        var request = request(url: url, method: "POST", body: Data(encoded.utf8))
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return request
    }

    static func check(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401: throw GitHubError.notAuthenticated
        case 403 where response.value(forHTTPHeaderField: "X-GitHub-SSO") != nil:
            throw GitHubError.organizationAccess("Authorize this connection for your organization’s SSO in GitHub.")
        case 429: throw GitHubError.rateLimited(response.value(forHTTPHeaderField: "Retry-After"))
        case 403 where response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
            || response.value(forHTTPHeaderField: "Retry-After") != nil:
            throw GitHubError.rateLimited(nil)
        case 403: throw GitHubError.insufficientPermissions
        default: throw GitHubError.httpError(response.statusCode)
        }
    }
}
