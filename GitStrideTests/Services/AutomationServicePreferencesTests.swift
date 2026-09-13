import Foundation
import Testing
@testable import GitStride

struct AutomationServicePreferencesTests {
    @Test func explicitSelectionOverridesTheBuildDefault() {
        let defaultOrigin = "https://default.invalid"
        #expect(AutomationServicePreferences.baseURL(savedOrigin: nil, defaultOrigin: defaultOrigin)?.absoluteString == defaultOrigin)
        #expect(AutomationServicePreferences.baseURL(savedOrigin: "https://custom.invalid", defaultOrigin: defaultOrigin)?.host == "custom.invalid")
        #expect(AutomationServicePreferences.baseURL(savedOrigin: "", defaultOrigin: defaultOrigin) == nil)
        #expect(AutomationServicePreferences.baseURL(savedOrigin: "invalid", defaultOrigin: defaultOrigin) == nil)
        #expect(AutomationServicePreferences.baseURL(savedOrigin: nil, defaultOrigin: "") == nil)
        #expect(AutomationServicePreferences.baseURL(savedOrigin: "https://custom.invalid", defaultOrigin: "")?.host == "custom.invalid")
        #expect(AutomationServicePreferences.baseURL(savedOrigin: nil, defaultOrigin: "http://localhost:8787")?.absoluteString == "http://localhost:8787")
    }

    @Test(arguments: [
        "http://worker.invalid", "http://localhost:8787", "worker.invalid", "https:///",
        "https://worker.invalid/api", "https://worker.invalid/%2F", "https://worker.invalid?",
        "https://worker.invalid#", "https://user:password@worker.invalid", "https://worker.invalid:65536",
        "https://bad host.invalid", "https://worker.invalid:0",
    ])
    func rejectsInvalidCustomOrigins(_ origin: String) {
        #expect(AutomationServicePreferences.validatedURL(origin) == nil)
    }

    @Test func canonicalOriginsKeepCredentialsTogether() throws {
        let plain = try #require(AutomationServicePreferences.validatedURL("https://worker.invalid"))
        let formatted = try #require(AutomationServicePreferences.validatedURL("  HTTPS://WORKER.INVALID:443/\n"))
        #expect(plain == formatted)
        #expect(AutomationServicePreferences.validatedURL("https://worker.invalid:8443/")?.absoluteString == "https://worker.invalid:8443")
    }

    @Test func savedChangesApplyOnlyToNewServices() throws {
        let suiteName = "AutomationServicePreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("https://first.invalid", forKey: AutomationServicePreferences.originKey)
        let running = try #require(AutomationService.configured(defaults: defaults))
        defaults.set("https://second.invalid", forKey: AutomationServicePreferences.originKey)
        #expect(running.baseURL.host == "first.invalid")
        #expect(AutomationService.configured(defaults: defaults)?.baseURL.host == "second.invalid")
        defaults.set("", forKey: AutomationServicePreferences.originKey)
        #expect(AutomationService.configured(defaults: defaults) == nil)
        #expect(running.baseURL.host == "first.invalid")
        defaults.removeObject(forKey: AutomationServicePreferences.originKey)
        #expect(AutomationService.configured(defaults: defaults)?.baseURL == AutomationServicePreferences.baseURL(savedOrigin: nil))
    }

    @Test @MainActor func managementCredentialsAreIsolatedByOrigin() throws {
        let host = "automation-test-\(UUID().uuidString.lowercased()).invalid"
        let firstURL = try #require(AutomationServicePreferences.validatedURL("https://\(host)"))
        let sameURL = try #require(AutomationServicePreferences.validatedURL("HTTPS://\(host.uppercased()):443/"))
        let otherURL = try #require(AutomationServicePreferences.validatedURL("https://other-\(host)"))
        let otherPortURL = try #require(AutomationServicePreferences.validatedURL("https://\(host):8443"))
        let first = ManagementTokenStore(baseURL: firstURL)
        let same = ManagementTokenStore(baseURL: sameURL)
        let other = ManagementTokenStore(baseURL: otherURL)
        let otherPort = ManagementTokenStore(baseURL: otherPortURL)
        defer {
            try? first.delete()
            try? other.delete()
        }

        try first.save("first-test-token")
        #expect(try same.load() == "first-test-token")
        #expect(try other.load() == nil)
        #expect(try otherPort.load() == nil)
        #expect(AutomationSetupModel(service: AutomationService(baseURL: firstURL)).phase == .loadingConnection)
        #expect(AutomationSetupModel(service: AutomationService(baseURL: otherURL)).phase == .disconnected)
        try other.save("other-test-token")
        try first.delete()
        #expect(try other.load() == "other-test-token")
        #expect(try same.load() == nil)
    }
}
