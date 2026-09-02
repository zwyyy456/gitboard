import { describe, expect, test } from "vitest";
import type { InstallationTokenProvider } from "../src/github-app-client";
import type { GraphQLRequester } from "../src/github-graphql";
import { RepositoryTruthReader } from "../src/repository-truth-reader";

describe("RepositoryTruthReader", () => {
    test("loads every page of closing Issues and their current closing PRs", async () => {
        const graphQL = new StubGraphQL([
            closingIssues([issue("ISSUE_1", 101, "owner/issues")], true, "issues-next"),
            closingIssues([issue("ISSUE_2", 202, "owner/other")], false, null),
            closingPullRequests([
                pullRequest("PR_1", "OPEN", false),
            ], true, "prs-next"),
            closingPullRequests([
                pullRequest("PR_2", "CLOSED", false),
            ], false, null),
            closingPullRequests([
                pullRequest("PR_3", "MERGED", false),
            ], false, null),
        ]);
        const reader = new RepositoryTruthReader(new StubTokenProvider(), graphQL);

        const result = await reader.loadWorkflowTruth(
            { id: 7, repositoryIDs: new Set([101, 202]) },
            { repositoryNameWithOwner: "owner/source", number: 42 }
        );

        expect(result).toEqual([
            {
                issueNodeID: "ISSUE_1",
                issueState: "OPEN",
                issueRepositoryID: 101,
                issueRepositoryNameWithOwner: "owner/issues",
                closingPullRequests: [
                    { nodeID: "PR_1", state: "OPEN", isDraft: false },
                    { nodeID: "PR_2", state: "CLOSED", isDraft: false },
                ],
            },
            {
                issueNodeID: "ISSUE_2",
                issueState: "OPEN",
                issueRepositoryID: 202,
                issueRepositoryNameWithOwner: "owner/other",
                closingPullRequests: [
                    { nodeID: "PR_3", state: "MERGED", isDraft: false },
                ],
            },
        ]);
        expect(graphQL.variables.map((variables) => variables.cursor)).toEqual([
            null,
            "issues-next",
            null,
            "prs-next",
            null,
        ]);
    });

    test("rejects a returned Issue outside the installation repository set", async () => {
        const reader = new RepositoryTruthReader(
            new StubTokenProvider(),
            new StubGraphQL([
                closingIssues([issue("ISSUE_1", 999, "other/private")], false, null),
            ])
        );

        await expect(reader.loadWorkflowTruth(
            { id: 7, repositoryIDs: new Set([101]) },
            { repositoryNameWithOwner: "owner/source", number: 42 }
        )).rejects.toMatchObject({
            code: "ISSUE_REPOSITORY_NOT_ACCESSIBLE",
        });
    });
});

class StubTokenProvider implements InstallationTokenProvider {
    async createInstallationAccessToken(): Promise<string> {
        return "installation-token";
    }
}

class StubGraphQL implements GraphQLRequester {
    readonly variables: Record<string, unknown>[] = [];

    constructor(private readonly responses: unknown[]) {}

    async request<T>(
        _token: string,
        _query: string,
        variables: Record<string, unknown>
    ): Promise<T> {
        this.variables.push(variables);
        const response = this.responses.shift();
        if (!response) throw new Error("Missing stub response");
        return response as T;
    }
}

function issue(id: string, repositoryID: number, nameWithOwner: string): object {
    return {
        id,
        state: "OPEN",
        repository: { databaseId: repositoryID, nameWithOwner },
    };
}

function pullRequest(id: string, state: string, isDraft: boolean): object {
    return { id, state, isDraft };
}

function closingIssues(nodes: object[], hasNextPage: boolean, endCursor: string | null): object {
    return {
        repository: {
            pullRequest: {
                closingIssuesReferences: { nodes, pageInfo: { hasNextPage, endCursor } },
            },
        },
    };
}

function closingPullRequests(
    nodes: object[],
    hasNextPage: boolean,
    endCursor: string | null
): object {
    return {
        node: {
            closedByPullRequestsReferences: { nodes, pageInfo: { hasNextPage, endCursor } },
        },
    };
}
