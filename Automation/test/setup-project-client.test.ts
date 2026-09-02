import { afterEach, describe, expect, test, vi } from "vitest";
import type { GraphQLRequester } from "../src/github-graphql";
import { SetupProjectClient } from "../src/setup-project-client";

afterEach(() => vi.unstubAllGlobals());

describe("SetupProjectClient", () => {
    test("keeps only the project and single-select field identity needed by setup", async () => {
        vi.stubGlobal("fetch", vi.fn()
            .mockResolvedValueOnce(githubResponse([{
                node_id: "PROJECT_NODE",
                number: 7,
                title: "Private roadmap",
                owner: { login: "octocat", ignored: "private" },
                ignored: "private",
            }]))
            .mockResolvedValueOnce(githubResponse([{
                node_id: "FIELD_NODE",
                name: "Status",
                data_type: "single_select",
                options: [{ id: "OPTION", name: { raw: "In review", html: "ignored" } }],
                ignored: "private",
            }, {
                node_id: "TEXT_FIELD",
                name: "Notes",
                data_type: "text",
            }])));
        const client = new SetupProjectClient(graphQL(), "2026-03-10");

        await expect(client.listProjects("oauth", "octocat")).resolves.toEqual([{
            nodeID: "PROJECT_NODE",
            number: 7,
            title: "Private roadmap",
        }]);
        await expect(client.listStatusFields("oauth", "octocat", 7)).resolves.toEqual([{
            nodeID: "FIELD_NODE",
            name: "Status",
            options: [{ id: "OPTION", name: "In review" }],
        }]);
    });

    test("fails before decoding when GitHub does not confirm the project scope", async () => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValue(Response.json([])));
        const client = new SetupProjectClient(graphQL(), "2026-03-10");

        await expect(client.listProjects("oauth", "octocat"))
            .rejects.toMatchObject({ code: "OAUTH_SCOPE_MISSING" });
    });

    test("proves visibility only when REST and installation GraphQL return the same private Issue", async () => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValue(githubResponse([{
            node_id: "ITEM_NODE",
            content: { node_id: "ISSUE_NODE", title: "ignored" },
        }])));
        const request = vi.fn(async () => ({
            nodes: [{
                id: "ISSUE_NODE",
                repository: { nameWithOwner: "octocat/private", isPrivate: true },
            }],
        }));
        const client = new SetupProjectClient({ request } as GraphQLRequester, "2026-03-10");

        await expect(client.probeContentVisibility(
            "oauth", "installation", "octocat", 7, "octocat/private"
        )).resolves.toBe("VERIFIED");
        expect(request).toHaveBeenCalledWith(
            "installation",
            expect.stringContaining("nodes(ids: $issueIDs)"),
            { issueIDs: ["ISSUE_NODE"] }
        );
    });
});

function githubResponse(body: unknown): Response {
    return Response.json(body, { headers: { "X-OAuth-Scopes": "project" } });
}

function graphQL(): GraphQLRequester {
    return { request: vi.fn() } as unknown as GraphQLRequester;
}
