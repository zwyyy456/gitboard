import Foundation
import Testing
@testable import GitStride

struct IssueRelationKindTests {
    @Test func relationDirectionsMatchGitHubMutationSemantics() {
        let issueID = "CURRENT"
        let relatedID = "RELATED"

        #expect(
            IssueRelationKind.parent.endpoints(issueID: issueID, relatedIssueID: relatedID)
                == IssueRelationEndpoints(issueID: relatedID, relatedIssueID: issueID)
        )
        #expect(
            IssueRelationKind.subIssue.endpoints(issueID: issueID, relatedIssueID: relatedID)
                == IssueRelationEndpoints(issueID: issueID, relatedIssueID: relatedID)
        )
        #expect(
            IssueRelationKind.blockedBy.endpoints(issueID: issueID, relatedIssueID: relatedID)
                == IssueRelationEndpoints(issueID: issueID, relatedIssueID: relatedID)
        )
        #expect(
            IssueRelationKind.blocking.endpoints(issueID: issueID, relatedIssueID: relatedID)
                == IssueRelationEndpoints(issueID: relatedID, relatedIssueID: issueID)
        )
    }
}
