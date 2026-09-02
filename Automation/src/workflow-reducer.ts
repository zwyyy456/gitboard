import type { DesiredStatus, IssueWorkflowTruth } from "./workflow-models";

export const WorkflowReducer = {
    reduce(issueTruth: IssueWorkflowTruth): DesiredStatus | null {
        if (issueTruth.closingPullRequests.some((pullRequest) => pullRequest.state === "MERGED")) {
            return "DONE";
        }
        if (issueTruth.issueState !== "OPEN") {
            return null;
        }
        if (issueTruth.closingPullRequests.some(
            (pullRequest) => pullRequest.state === "OPEN" && !pullRequest.isDraft
        )) {
            return "IN_REVIEW";
        }
        if (issueTruth.closingPullRequests.some(
            (pullRequest) => pullRequest.state === "OPEN" && pullRequest.isDraft
        )) {
            return "IN_PROGRESS";
        }
        if (issueTruth.closingPullRequests.length > 0
            && issueTruth.closingPullRequests.every(
                (pullRequest) => pullRequest.state === "CLOSED"
            )) {
            return "IN_PROGRESS";
        }
        return null;
    },
};
