import Foundation
import Testing
@testable import GitStride

struct QuickCreateParserTests {
    @Test func parsesTriageQualifiersWithoutIncludingThemInTheTitle() {
        let request = QuickCreateParser.parse(
            "> Repair login flow repo:acme/app status:Todo priority:High @me @octocat #bug"
        )

        #expect(request.title == "Repair login flow")
        #expect(request.repository == "acme/app")
        #expect(request.status == "Todo")
        #expect(request.priority == "High")
        #expect(request.assignees == ["me", "octocat"])
        #expect(request.labels == ["bug"])
    }
}
