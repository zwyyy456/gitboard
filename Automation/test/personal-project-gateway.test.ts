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
    test("updates every matching personal Project and falls back to in progress", async () => {
        vi.stubGlobal("fetch", vi.fn()
            .mockResolvedValueOnce(projectResponse([item("ITEM_1", "ISSUE")]))
            .mockResolvedValueOnce(projectResponse([item("ITEM_2", "ISSUE")])));
        const writer = new StubWriter();
        const catalog = {
            async listProjects() {
                return [
                    { nodeID: "PROJECT", number: 1, title: "Template" },
                    { nodeID: "PROJECT_2", number: 2, title: "Second" },
                ];
            },
            async listStatusFields(_token: string, _owner: string, number: number) {
                if (number === 1) return new StubProjectCatalog().listStatusFields();
                return [{
                    nodeID: "STATUS_FIELD_2",
                    name: "Status",
                    options: [
                        { id: "PROGRESS_OPTION_2", name: "In Progress" },
                        { id: "DONE_OPTION_2", name: "Done" },
                    ],
                }];
            },
            async ensureStatusOption() {
                throw new Error("Unexpected ensureStatusOption call");
            },
        };
        const gateway = new PersonalProjectGateway(
            new StubAccessTokens(),
            writer,
            catalog,
            "2026-03-10"
        );

        await expect(gateway.applyStatuses(project, [
            assignment("ISSUE", "owner/repository", "IN_REVIEW"),
        ])).resolves.toEqual({ ISSUE: "APPLIED" });
        expect(writer.updates).toEqual([
            { itemNodeID: "ITEM_1", optionID: "REVIEW_OPTION" },
            { itemNodeID: "ITEM_2", optionID: "PROGRESS_OPTION_2" },
        ]);
    });

    test("prefers exact option names, then ignores case without ignoring spaces", async () => {
        vi.stubGlobal("fetch", vi.fn()
            .mockResolvedValueOnce(projectResponse([item("ITEM_1", "ISSUE")]))
            .mockResolvedValueOnce(projectResponse([item("ITEM_2", "ISSUE")]))
            .mockResolvedValueOnce(projectResponse([item("ITEM_3", "ISSUE")]))
            .mockResolvedValueOnce(projectResponse([item("ITEM_4", "ISSUE")])));
        const writer = new StubWriter();
        const catalog = {
            async listProjects() {
                return [
                    { nodeID: "PROJECT", number: 1, title: "Template" },
                    { nodeID: "PROJECT_2", number: 2, title: "Exact" },
                    { nodeID: "PROJECT_3", number: 3, title: "Case fallback" },
                    { nodeID: "PROJECT_4", number: 4, title: "Whitespace mismatch" },
                ];
            },
            async listStatusFields(_token: string, _owner: string, number: number) {
                if (number === 1) return new StubProjectCatalog().listStatusFields();
                const reviewOptions = number === 2
                    ? [
                        { id: "CASE_OPTION_2", name: "In review" },
                        { id: "EXACT_OPTION_2", name: "In Review" },
                    ]
                    : number === 3
                        ? [{ id: "CASE_OPTION_3", name: "In review" }]
                        : [{ id: "SPACED_OPTION_4", name: "In  Review" }];
                return [{
                    nodeID: `STATUS_FIELD_${number}`,
                    name: "Status",
                    options: [
                        { id: `PROGRESS_OPTION_${number}`, name: "In Progress" },
                        ...reviewOptions,
                        { id: `DONE_OPTION_${number}`, name: "Done" },
                    ],
                }];
            },
            async ensureStatusOption() {
                throw new Error("Unexpected ensureStatusOption call");
            },
        };
        const gateway = new PersonalProjectGateway(
            new StubAccessTokens(),
            writer,
            catalog,
            "2026-03-10"
        );

        await expect(gateway.applyStatuses(project, [
            assignment("ISSUE", "owner/repository", "IN_REVIEW"),
        ])).resolves.toEqual({ ISSUE: "APPLIED" });
        expect(writer.updates).toEqual([
            { itemNodeID: "ITEM_1", optionID: "REVIEW_OPTION" },
            { itemNodeID: "ITEM_2", optionID: "EXACT_OPTION_2" },
            { itemNodeID: "ITEM_3", optionID: "CASE_OPTION_3" },
            { itemNodeID: "ITEM_4", optionID: "PROGRESS_OPTION_4" },
        ]);
    });

    test("adds In review only to a Project containing a matching ready Issue", async () => {
        vi.stubGlobal("fetch", vi.fn()
            .mockResolvedValueOnce(projectResponse([item("ITEM_1", "ISSUE")]))
            .mockResolvedValueOnce(projectResponse([])));
        const writer = new StubWriter();
        const ensureCalls: Array<{ fieldNodeID: string; optionName: string }> = [];
        const catalog = {
            async listProjects() {
                return [
                    { nodeID: "PROJECT", number: 1, title: "Template" },
                    { nodeID: "PROJECT_2", number: 2, title: "Unmatched" },
                ];
            },
            async listStatusFields(_token: string, _owner: string, number: number) {
                return [{
                    nodeID: `STATUS_FIELD_${number}`,
                    name: "Status",
                    options: [
                        { id: `PROGRESS_OPTION_${number}`, name: "In Progress" },
                        { id: `DONE_OPTION_${number}`, name: "Done" },
                    ],
                }];
            },
            async ensureStatusOption(
                _token: string,
                fieldNodeID: string,
                optionName: string
            ) {
                ensureCalls.push({ fieldNodeID, optionName });
                return { id: "CREATED_REVIEW", name: optionName };
            },
        };
        const gateway = new PersonalProjectGateway(
            new StubAccessTokens(),
            writer,
            catalog,
            "2026-03-10"
        );
        const ensureProject: PersonalProjectConfiguration = {
            ...project,
            statusFieldNodeID: "STATUS_FIELD_1",
            statusOptionIDs: {
                IN_PROGRESS: "PROGRESS_OPTION_1",
                IN_REVIEW: "PROGRESS_OPTION_1",
                DONE: "DONE_OPTION_1",
            },
            reviewStatusPolicy: "ENSURE_IN_REVIEW",
        };

        await expect(gateway.applyStatuses(ensureProject, [
            assignment("ISSUE", "owner/repository", "IN_REVIEW"),
        ])).resolves.toEqual({ ISSUE: "APPLIED" });
        expect(ensureCalls).toEqual([{
            fieldNodeID: "STATUS_FIELD_1",
            optionName: "In review",
        }]);
        expect(writer.updates).toEqual([
            { itemNodeID: "ITEM_1", optionID: "CREATED_REVIEW" },
        ]);
    });

    test("keeps ready Issues in progress when the user declines Project changes", async () => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValueOnce(
            projectResponse([item("ITEM_1", "ISSUE")])
        ));
        const writer = new StubWriter();
        const gateway = new PersonalProjectGateway(
            new StubAccessTokens(),
            writer,
            {
                async listProjects() {
                    return [{ nodeID: "PROJECT", number: 1, title: "Template" }];
                },
                async listStatusFields() {
                    return [{
                        nodeID: "STATUS_FIELD",
                        name: "Status",
                        options: [
                            { id: "PROGRESS_OPTION", name: "In Progress" },
                            { id: "DONE_OPTION", name: "Done" },
                        ],
                    }];
                },
                async ensureStatusOption() {
                    throw new Error("Unexpected ensureStatusOption call");
                },
            },
            "2026-03-10"
        );

        await expect(gateway.applyStatuses({
            ...project,
            statusOptionIDs: {
                ...project.statusOptionIDs,
                IN_REVIEW: "PROGRESS_OPTION",
            },
            reviewStatusPolicy: "USE_IN_PROGRESS",
        }, [
            assignment("ISSUE", "owner/repository", "IN_REVIEW"),
        ])).resolves.toEqual({ ISSUE: "APPLIED" });
        expect(writer.updates).toEqual([
            { itemNodeID: "ITEM_1", optionID: "PROGRESS_OPTION" },
        ]);
    });

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

    test("classifies a server failure before checking the project scope", async () => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValue(Response.json(
            { message: "unavailable" },
            { status: 503 }
        )));

        await expect(makeGateway(new StubWriter()).applyStatuses(project, [
            assignment("ISSUE", "owner/repository", "IN_PROGRESS"),
        ])).rejects.toMatchObject({ code: "TRANSIENT_GITHUB_FAILURE" });
    });

    test("classifies an ordinary 403 as an invalid runtime configuration", async () => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValue(projectResponse(
            { message: "forbidden" },
            { status: 403 }
        )));

        await expect(makeGateway(new StubWriter()).applyStatuses(project, [
            assignment("ISSUE", "owner/repository", "IN_PROGRESS"),
        ])).rejects.toMatchObject({ code: "PROJECT_CONFIGURATION_INVALID" });
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
    reviewStatusPolicy: "USE_CONFIGURED_OPTION",
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
    return new PersonalProjectGateway(
        new StubAccessTokens(),
        writer,
        new StubProjectCatalog(),
        "2026-03-10"
    );
}

class StubProjectCatalog {
    async listProjects() {
        return [{ nodeID: "PROJECT", number: 1, title: "Template" }];
    }

    async listStatusFields() {
        return [{
            nodeID: "STATUS_FIELD",
            name: "Status",
            options: [
                { id: "PROGRESS_OPTION", name: "In Progress" },
                { id: "REVIEW_OPTION", name: "In Review" },
                { id: "DONE_OPTION", name: "Done" },
            ],
        }];
    }

    async ensureStatusOption(): Promise<{ id: string; name: string }> {
        throw new Error("Unexpected ensureStatusOption call");
    }
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
