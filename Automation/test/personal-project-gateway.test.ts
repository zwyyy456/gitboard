import { afterEach, describe, expect, test, vi } from "vitest";
import type { AccessTokenProvider } from "../src/oauth-credential-provider";
import {
    PersonalProjectGateway,
    type IssueStatusAssignment,
    type PersonalProjectConfiguration,
    type ProjectStatusWriter,
    ProjectStatusWriterError,
} from "../src/personal-project-gateway";

afterEach(() => vi.unstubAllGlobals());

describe("PersonalProjectGateway", () => {
    test("groups Issues by their own repository and matches exact node IDs", async () => {
        const fetchMock = vi.fn()
            .mockResolvedValueOnce(projectResponse([
                item("ITEM_1", "ISSUE_1"),
                item("UNRELATED_ITEM", "UNRELATED_ISSUE"),
            ]))
            .mockResolvedValueOnce(projectResponse([item("ITEM_2", "ISSUE_2")]));
        vi.stubGlobal("fetch", fetchMock);
        const writer = new StubWriter();
        const gateway = makeGateway(writer);

        await expect(gateway.applyStatuses(project, [
            assignment("ISSUE_1", "owner/repo-a", "IN_REVIEW"),
            assignment("ISSUE_2", "owner/repo-b", "DONE"),
        ])).resolves.toEqual({ ISSUE_1: "APPLIED", ISSUE_2: "APPLIED" });

        expect(fetchMock.mock.calls.map(([url]) => new URL(url).searchParams.get("q"))).toEqual([
            "repo:owner/repo-a is:issue",
            "repo:owner/repo-b is:issue",
        ]);
        expect(writer.updates).toEqual([
            { itemNodeID: "ITEM_1", optionID: "REVIEW_OPTION" },
            { itemNodeID: "ITEM_2", optionID: "DONE_OPTION" },
        ]);
    });

    test("follows Link pagination before classifying a missing Issue", async () => {
        const nextURL = "https://api.github.com/users/owner/projectsV2/1/items?after=cursor";
        vi.stubGlobal("fetch", vi.fn()
            .mockResolvedValueOnce(projectResponse(
                [item("UNRELATED", "OTHER")],
                { headers: { Link: `<${nextURL}>; rel="next"` } }
            ))
            .mockResolvedValueOnce(projectResponse([item("ITEM", "ISSUE")])));
        const writer = new StubWriter();

        await expect(makeGateway(writer).applyStatuses(project, [
            assignment("ISSUE", "owner/repository", "IN_PROGRESS"),
        ])).resolves.toEqual({ ISSUE: "APPLIED" });
        expect(writer.updates).toHaveLength(1);
    });

    test("returns NOT_IN_PROJECT only after a complete scan without opaque candidates", async () => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValue(projectResponse([
            item("UNRELATED", "OTHER"),
        ])));
        const writer = new StubWriter();

        await expect(makeGateway(writer).applyStatuses(project, [
            assignment("ISSUE", "owner/repository", "IN_PROGRESS"),
        ])).resolves.toEqual({ ISSUE: "NOT_IN_PROJECT" });
        expect(writer.updates).toEqual([]);
    });

    test("fails closed when an unresolved scan contains an opaque candidate", async () => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValue(projectResponse([
            { node_id: "OPAQUE_ITEM", content: { title: "private" } },
        ])));
        const writer = new StubWriter();

        await expect(makeGateway(writer).applyStatuses(project, [
            assignment("ISSUE", "owner/repository", "IN_PROGRESS"),
        ])).rejects.toMatchObject({ code: "VISIBILITY_INDETERMINATE" });
        expect(writer.updates).toEqual([]);
    });

    test("reports the actual missing project scope before classifying a 403", async () => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValue(Response.json(
            { message: "forbidden" },
            { status: 403, headers: { "X-OAuth-Scopes": "" } }
        )));

        await expect(makeGateway(new StubWriter()).applyStatuses(project, [
            assignment("ISSUE", "owner/repository", "IN_PROGRESS"),
        ])).rejects.toMatchObject({ code: "OAUTH_SCOPE_MISSING" });
    });

    test("classifies a rate-limited 403 as transient", async () => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValue(projectResponse(
            { message: "rate limited" },
            { status: 403, headers: { "Retry-After": "60" } }
        )));

        await expect(makeGateway(new StubWriter()).applyStatuses(project, [
            assignment("ISSUE", "owner/repository", "IN_PROGRESS"),
        ])).rejects.toMatchObject({ code: "TRANSIENT_GITHUB_FAILURE" });
    });

    test("re-resolves once when the looked-up item was deleted", async () => {
        vi.stubGlobal("fetch", vi.fn()
            .mockResolvedValueOnce(projectResponse([item("OLD_ITEM", "ISSUE")]))
            .mockResolvedValueOnce(projectResponse([])));
        const writer = new StubWriter([new ProjectStatusWriterError("ITEM_NOT_FOUND")]);

        await expect(makeGateway(writer).applyStatuses(project, [
            assignment("ISSUE", "owner/repository", "DONE"),
        ])).resolves.toEqual({ ISSUE: "NOT_IN_PROJECT" });
        expect(writer.updates).toEqual([{ itemNodeID: "OLD_ITEM", optionID: "DONE_OPTION" }]);
    });

    test("writes once more when re-resolution finds a replacement item", async () => {
        vi.stubGlobal("fetch", vi.fn()
            .mockResolvedValueOnce(projectResponse([item("OLD_ITEM", "ISSUE")]))
            .mockResolvedValueOnce(projectResponse([item("NEW_ITEM", "ISSUE")])));
        const writer = new StubWriter([new ProjectStatusWriterError("ITEM_NOT_FOUND")]);

        await expect(makeGateway(writer).applyStatuses(project, [
            assignment("ISSUE", "owner/repository", "DONE"),
        ])).resolves.toEqual({ ISSUE: "APPLIED" });
        expect(writer.updates).toEqual([
            { itemNodeID: "OLD_ITEM", optionID: "DONE_OPTION" },
            { itemNodeID: "NEW_ITEM", optionID: "DONE_OPTION" },
        ]);
    });
});

const project: PersonalProjectConfiguration = {
    oauthCredentialID: "credential",
    ownerLogin: "owner",
    number: 1,
    projectNodeID: "PROJECT",
    statusFieldNodeID: "STATUS_FIELD",
    statusOptionIDs: {
        IN_PROGRESS: "PROGRESS_OPTION",
        IN_REVIEW: "REVIEW_OPTION",
        DONE: "DONE_OPTION",
    },
};

class StubAccessTokens implements AccessTokenProvider {
    async withValidAccessToken<T>(
        _credentialID: string,
        operation: (token: string) => Promise<T>
    ): Promise<T> {
        return operation("oauth-token");
    }
}

class StubWriter implements ProjectStatusWriter {
    readonly updates: Array<{ itemNodeID: string; optionID: string }> = [];

    constructor(private readonly failures: Error[] = []) {}

    async updateStatus(
        _token: string,
        _project: PersonalProjectConfiguration,
        itemNodeID: string,
        optionID: string
    ): Promise<void> {
        this.updates.push({ itemNodeID, optionID });
        const failure = this.failures.shift();
        if (failure) throw failure;
    }
}

function makeGateway(writer: StubWriter): PersonalProjectGateway {
    return new PersonalProjectGateway(new StubAccessTokens(), writer, "2026-03-10");
}

function assignment(
    issueNodeID: string,
    issueRepositoryNameWithOwner: string,
    desiredStatus: "IN_PROGRESS" | "IN_REVIEW" | "DONE"
): IssueStatusAssignment {
    return { issueNodeID, issueRepositoryNameWithOwner, desiredStatus };
}

function item(nodeID: string, contentNodeID: string): object {
    return {
        node_id: nodeID,
        content: {
            node_id: contentNodeID,
            title: "private title that must not propagate",
            body: "private body that must not propagate",
        },
    };
}

function projectResponse(body: unknown, init: ResponseInit = {}): Response {
    const headers = new Headers(init.headers);
    headers.set("X-OAuth-Scopes", "project");
    return Response.json(body, { ...init, headers });
}
