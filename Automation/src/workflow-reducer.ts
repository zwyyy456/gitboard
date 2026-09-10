import type { DesiredStatus, IssueWorkflowTruth } from "./workflow-models";

export const WorkflowReducer = {
    reduce(issueTruth: IssueWorkflowTruth): DesiredStatus | null {
        const pullRequests = issueTruth.closingPullRequests;
        if (pullRequests.length > 0
            && pullRequests.every((pullRequest) => pullRequest.state === "MERGED")) {
            return "DONE";
        }
        if (pullRequests.some(
            (pullRequest) => pullRequest.state === "OPEN" && pullRequest.isDraft
        )) {
            return "IN_PROGRESS";
        }
        if (pullRequests.some(
            (pullRequest) => pullRequest.state === "OPEN" && !pullRequest.isDraft
        )) {
            return "IN_REVIEW";
        }
        if (issueTruth.issueState !== "OPEN") {
            return null;
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
