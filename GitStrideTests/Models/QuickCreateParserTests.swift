import Foundation
import Testing
@testable import GitStride

struct QuickCreateParserTests {
    @Test(arguments: ["> ", ">", ""])
    func parsesTriageQualifiersWithoutIncludingThemInTheTitle(_ prefix: String) {
        let request = QuickCreateParser.parse(
            "\(prefix)Repair login flow repo:acme/app status:Todo priority:High @me @octocat #bug"
        )

        #expect(request.title == "Repair login flow")
        #expect(request.repository == "acme/app")
        #expect(request.status == "Todo")
        #expect(request.priority == "High")
        #expect(request.assignees == ["me", "octocat"])
        #expect(request.labels == ["bug"])
    }

    @Test func preservesGreaterThanInsideTheTitle() {
        let request = QuickCreateParser.parse("> Fix width > 400")
        #expect(request.title == "Fix width > 400")
    }
}
