import {
    GitHubAppRequestError,
    type InstallationTokenProvider,
} from "./github-app-client";
import { GitHubGraphQLError, type GraphQLRequester } from "./github-graphql";
import type {
    ClosingPullRequestTruth,
    InstallationContext,
    IssueWorkflowTruth,
    SourcePullRequest,
} from "./workflow-models";

export type RepositoryTruthErrorCode =
    | "ISSUE_REPOSITORY_NOT_ACCESSIBLE"
    | "REPOSITORY_TRUTH_AUTHENTICATION_FAILED"
    | "REPOSITORY_TRUTH_FORBIDDEN"
    | "SOURCE_PULL_REQUEST_NOT_FOUND"
    | "TRANSIENT_GITHUB_FAILURE"
    | "GITHUB_RESPONSE_INVALID";

export class RepositoryTruthError extends Error {
    constructor(readonly code: RepositoryTruthErrorCode) {
        super(code);
    }
}

export class RepositoryTruthReader {
    constructor(
        private readonly appClient: InstallationTokenProvider,
        private readonly graphQL: GraphQLRequester
    ) {}

    async loadWorkflowTruth(
        installation: InstallationContext,
        sourcePullRequest: SourcePullRequest
    ): Promise<IssueWorkflowTruth[]> {
        if (!sourcePullRequest.repositoryNodeID
            || !Number.isSafeInteger(sourcePullRequest.number)
            || sourcePullRequest.number < 1) {
            throw new RepositoryTruthError("GITHUB_RESPONSE_INVALID");
        }

        try {
            const token = await this.appClient.createInstallationAccessToken(installation.id);
            const issues = await this.loadClosingIssues(
                token,
                sourcePullRequest.repositoryNodeID,
                sourcePullRequest.number
            );
            const truth: IssueWorkflowTruth[] = [];
            for (const issue of issues) {
                if (!installation.repositoryNodeIDs.has(issue.repositoryNodeID)) {
                    throw new RepositoryTruthError("ISSUE_REPOSITORY_NOT_ACCESSIBLE");
                }
                truth.push({
                    issueNodeID: issue.nodeID,
                    issueState: issue.state,
                    issueRepositoryNodeID: issue.repositoryNodeID,
                    issueRepositoryNameWithOwner: issue.repositoryNameWithOwner,
                    closingPullRequests: await this.loadClosingPullRequests(token, issue.nodeID),
                });
            }
            return truth;
        } catch (error) {
            if (error instanceof RepositoryTruthError) {
                throw error;
            }
            if (error instanceof GitHubGraphQLError) {
                throw mapGraphQLError(error);
            }
            if (error instanceof GitHubAppRequestError) {
                throw error.retryable
                    ? new RepositoryTruthError("TRANSIENT_GITHUB_FAILURE")
                    : mapHTTPStatus(error.status);
            }
            throw new RepositoryTruthError("TRANSIENT_GITHUB_FAILURE");
        }
    }

    private async loadClosingIssues(
        token: string,
        repositoryNodeID: string,
        pullRequestNumber: number
    ): Promise<ClosingIssue[]> {
        const issues: ClosingIssue[] = [];
        let cursor: string | null = null;
        do {
            const data: unknown = await this.graphQL.request(
                token,
                closingIssuesQuery,
                { repositoryNodeID, pullRequestNumber, cursor }
            );
            const connection = readConnection(data, ["node", "pullRequest", "closingIssuesReferences"]);
            for (const node of connection.nodes) {
                issues.push(readClosingIssue(node));
            }
            cursor = nextCursor(connection.pageInfo);
        } while (cursor);
        return issues;
    }

    private async loadClosingPullRequests(
        token: string,
        issueNodeID: string
    ): Promise<ClosingPullRequestTruth[]> {
        const pullRequests: ClosingPullRequestTruth[] = [];
        let cursor: string | null = null;
        do {
            const data: unknown = await this.graphQL.request(
                token,
                closingPullRequestsQuery,
                { issueNodeID, cursor }
            );
            const connection = readConnection(data, ["node", "closedByPullRequestsReferences"]);
            for (const node of connection.nodes) {
                pullRequests.push(readClosingPullRequest(node));
            }
            cursor = nextCursor(connection.pageInfo);
        } while (cursor);
        return pullRequests;
    }
}

interface ClosingIssue {
    nodeID: string;
    state: "OPEN" | "CLOSED";
    repositoryNodeID: string;
    repositoryNameWithOwner: string;
}

interface Connection {
    nodes: unknown[];
    pageInfo: unknown;
}

const closingIssuesQuery = `
query ClosingIssues(
  $repositoryNodeID: ID!
  $pullRequestNumber: Int!
  $cursor: String
) {
  node(id: $repositoryNodeID) {
    ... on Repository {
      pullRequest(number: $pullRequestNumber) {
        closingIssuesReferences(first: 100, after: $cursor) {
          nodes {
            id
            state
            repository { id nameWithOwner }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
}`;

const closingPullRequestsQuery = `
query ClosingPullRequests($issueNodeID: ID!, $cursor: String) {
  node(id: $issueNodeID) {
    ... on Issue {
      closedByPullRequestsReferences(
        first: 100
        after: $cursor
        includeClosedPrs: true
      ) {
        nodes { id state isDraft }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}`;

function readConnection(value: unknown, path: string[]): Connection {
    let current = value;
    for (const component of path) {
        if (!isRecord(current) || !(component in current)) {
            if (component === "pullRequest") {
                throw new RepositoryTruthError("SOURCE_PULL_REQUEST_NOT_FOUND");
            }
            throw new RepositoryTruthError("GITHUB_RESPONSE_INVALID");
        }
        current = current[component];
        if (current == null) {
            if (component === "node" || component === "pullRequest") {
                throw new RepositoryTruthError("SOURCE_PULL_REQUEST_NOT_FOUND");
            }
            throw new RepositoryTruthError("GITHUB_RESPONSE_INVALID");
        }
    }
    if (!isRecord(current) || !Array.isArray(current.nodes) || !("pageInfo" in current)) {
        throw new RepositoryTruthError("GITHUB_RESPONSE_INVALID");
    }
    return { nodes: current.nodes, pageInfo: current.pageInfo };
}

function readClosingIssue(value: unknown): ClosingIssue {
    if (!isRecord(value)
        || typeof value.id !== "string"
        || (value.state !== "OPEN" && value.state !== "CLOSED")
        || !isRecord(value.repository)
        || typeof value.repository.id !== "string"
        || typeof value.repository.nameWithOwner !== "string") {
        throw new RepositoryTruthError("GITHUB_RESPONSE_INVALID");
    }
    return {
        nodeID: value.id,
        state: value.state,
        repositoryNodeID: value.repository.id,
        repositoryNameWithOwner: value.repository.nameWithOwner,
    };
}

function readClosingPullRequest(value: unknown): ClosingPullRequestTruth {
    if (!isRecord(value)
        || typeof value.id !== "string"
        || (value.state !== "OPEN" && value.state !== "CLOSED" && value.state !== "MERGED")
        || typeof value.isDraft !== "boolean") {
        throw new RepositoryTruthError("GITHUB_RESPONSE_INVALID");
    }
    return { nodeID: value.id, state: value.state, isDraft: value.isDraft };
}

function nextCursor(value: unknown): string | null {
    if (!isRecord(value) || typeof value.hasNextPage !== "boolean") {
        throw new RepositoryTruthError("GITHUB_RESPONSE_INVALID");
    }
    if (!value.hasNextPage) return null;
    if (typeof value.endCursor !== "string") {
        throw new RepositoryTruthError("GITHUB_RESPONSE_INVALID");
    }
    return value.endCursor;
}

function mapGraphQLError(error: GitHubGraphQLError): RepositoryTruthError {
    switch (error.kind) {
    case "AUTHENTICATION":
        return new RepositoryTruthError("REPOSITORY_TRUTH_AUTHENTICATION_FAILED");
    case "FORBIDDEN":
        return new RepositoryTruthError("REPOSITORY_TRUTH_FORBIDDEN");
    case "NOT_FOUND":
        return new RepositoryTruthError("SOURCE_PULL_REQUEST_NOT_FOUND");
    case "TRANSIENT":
        return new RepositoryTruthError("TRANSIENT_GITHUB_FAILURE");
    case "INVALID_RESPONSE":
        return new RepositoryTruthError("GITHUB_RESPONSE_INVALID");
    }
}

function mapHTTPStatus(status: number): RepositoryTruthError {
    if (status === 401) {
        return new RepositoryTruthError("REPOSITORY_TRUTH_AUTHENTICATION_FAILED");
    }
    if (status === 403) {
        return new RepositoryTruthError("REPOSITORY_TRUTH_FORBIDDEN");
    }
    if (status === 429 || status >= 500) {
        return new RepositoryTruthError("TRANSIENT_GITHUB_FAILURE");
    }
    return new RepositoryTruthError("GITHUB_RESPONSE_INVALID");
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
}

function isPositiveInteger(value: unknown): value is number {
    return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}
