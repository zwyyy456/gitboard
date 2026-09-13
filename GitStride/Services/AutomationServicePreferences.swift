import Foundation

enum AutomationServicePreferences {
    // Missing uses the build default; an empty value explicitly disables the service.
    static let originKey = "automationServiceOrigin"

    static var buildDefaultOrigin: String? {
        Bundle.main.object(forInfoDictionaryKey: "GitStrideAutomationBaseURL") as? String
    }

    static func baseURL(
        savedOrigin: String?,
        defaultOrigin: String? = buildDefaultOrigin
    ) -> URL? {
        if let savedOrigin {
            return validatedURL(savedOrigin)
        }
        guard let defaultOrigin else { return nil }
        return validatedURL(defaultOrigin, allowsLocalhost: true)
    }

    static func validatedURL(_ value: String, allowsLocalhost: Bool = false) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed, encodingInvalidCharacters: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              scheme == "https" || (allowsLocalhost && scheme == "http" && host == "localhost"),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        components.path = ""
        if components.port == (scheme == "https" ? 443 : 80) {
            components.port = nil
        }
        return components.url
    }
}
