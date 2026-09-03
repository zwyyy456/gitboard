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
}

private struct StubManagementTokenStore: ManagementTokenStoring {
    let token: String?

    func load() throws -> String? { token }
    func save(_ token: String) throws {}
    func delete() throws {}
}
