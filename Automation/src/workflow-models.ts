export interface InstallationContext {
    id: number;
    repositoryNodeIDs: ReadonlySet<string>;
}

export interface SourcePullRequest {
    repositoryNodeID: string;
    number: number;
}

export interface ClosingPullRequestTruth {
    state: "OPEN" | "CLOSED" | "MERGED";
    isDraft: boolean;
}

export interface IssueWorkflowTruth {
    issueNodeID: string;
    issueState: "OPEN" | "CLOSED";
    issueRepositoryNameWithOwner: string;
    closingPullRequests: ClosingPullRequestTruth[];
}

export type DesiredStatus = "DONE" | "IN_REVIEW" | "IN_PROGRESS";
