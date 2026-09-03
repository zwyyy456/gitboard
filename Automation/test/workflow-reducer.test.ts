import { describe, expect, test } from "vitest";
import type {
    ClosingPullRequestTruth,
    DesiredStatus,
    IssueWorkflowTruth,
} from "../src/workflow-models";
import { WorkflowReducer } from "../src/workflow-reducer";

describe("WorkflowReducer", () => {
    test.each<{
        name: string;
        issueState: IssueWorkflowTruth["issueState"];
        pullRequests: ClosingPullRequestTruth[];
        expected: DesiredStatus | null;
    }>([
        {
            name: "merged wins over an open ready PR",
            issueState: "CLOSED",
            pullRequests: [pr("OPEN", false), pr("MERGED", false)],
            expected: "DONE",
        },
        {
            name: "an open ready PR wins over a draft PR",
            issueState: "OPEN",
            pullRequests: [pr("OPEN", true), pr("OPEN", false)],
            expected: "IN_REVIEW",
        },
        {
            name: "an open draft PR is in progress",
            issueState: "OPEN",
            pullRequests: [pr("OPEN", true)],
            expected: "IN_PROGRESS",
        },
        {
            name: "all closed unmerged PRs return the Issue to in progress",
            issueState: "OPEN",
            pullRequests: [pr("CLOSED", false), pr("CLOSED", true)],
            expected: "IN_PROGRESS",
        },
        {
            name: "a closed Issue without a merged PR is unchanged",
            issueState: "CLOSED",
            pullRequests: [pr("CLOSED", false)],
            expected: null,
        },
        {
            name: "an Issue without closing PRs is unchanged",
            issueState: "OPEN",
            pullRequests: [],
            expected: null,
        },
    ])("$name", ({ issueState, pullRequests, expected }) => {
        expect(WorkflowReducer.reduce(issue(issueState, pullRequests))).toBe(expected);
    });
});

function issue(
    issueState: IssueWorkflowTruth["issueState"],
    closingPullRequests: ClosingPullRequestTruth[]
): IssueWorkflowTruth {
    return {
        issueNodeID: "ISSUE",
        issueState,
        issueRepositoryNameWithOwner: "owner/repository",
        closingPullRequests,
    };
}

function pr(
    state: ClosingPullRequestTruth["state"],
    isDraft: boolean
): ClosingPullRequestTruth {
    return { state, isDraft };
}
