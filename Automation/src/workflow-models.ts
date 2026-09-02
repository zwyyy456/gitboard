export interface InstallationContext {
    id: number;
    repositoryIDs: ReadonlySet<number>;
}

export interface SourcePullRequest {
    repositoryNameWithOwner: string;
    number: number;
}

export interface ClosingPullRequestTruth {
    nodeID: string;
    state: "OPEN" | "CLOSED" | "MERGED";
    isDraft: boolean;
}

export interface IssueWorkflowTruth {
    issueNodeID: string;
    issueState: "OPEN" | "CLOSED";
    issueRepositoryID: number;
    issueRepositoryNameWithOwner: string;
    closingPullRequests: ClosingPullRequestTruth[];
}

export type DesiredStatus = "DONE" | "IN_REVIEW" | "IN_PROGRESS";
