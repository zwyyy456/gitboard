import Foundation
import Security

struct GitHubOAuthCredential: Codable, Sendable {
    let clientID: String
    let account: GitHubAccount
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let refreshExpiresAt: Date
}

protocol GitHubCredentialStoring: Sendable {
    func load() throws -> GitHubOAuthCredential?
    func save(_ credential: GitHubOAuthCredential) throws
    func delete() throws
}

struct GitHubCredentialStore: GitHubCredentialStoring {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.gitstride.app.github-oauth",
         kSecAttrAccount as String: "github.com"]
    }

    func load() throws -> GitHubOAuthCredential? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let credential = try? JSONDecoder().decode(GitHubOAuthCredential.self, from: data) else {
            throw GitHubError.credentialStorage
        }
        return credential
    }

    func save(_ credential: GitHubOAuthCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw GitHubError.credentialStorage }
        var query = query
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw GitHubError.credentialStorage }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GitHubError.credentialStorage }
    }
}
