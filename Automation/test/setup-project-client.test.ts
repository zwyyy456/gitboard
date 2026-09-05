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

    test("classifies a server failure before checking the project scope", async () => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValue(Response.json(
            { message: "unavailable" },
            { status: 503 }
        )));
        const client = new SetupProjectClient(graphQL(), "2026-03-10");

        await expect(client.listProjects("oauth", "octocat"))
            .rejects.toMatchObject({ code: "TRANSIENT_GITHUB_FAILURE" });
    });

    test("classifies an ordinary 403 as missing project write access", async () => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValue(githubResponse(
            { message: "forbidden" },
            { status: 403 }
        )));
        const client = new SetupProjectClient(graphQL(), "2026-03-10");

        await expect(client.listProjects("oauth", "octocat"))
            .rejects.toMatchObject({ code: "PROJECT_WRITE_FORBIDDEN" });
    });

    test("prefers an exact In review option and otherwise ignores only case", async () => {
        const request = vi.fn()
            .mockResolvedValueOnce({
                node: {
                    id: "FIELD",
                    options: [
                        option("CASE", "In Review"),
                        option("EXACT", "In review"),
                    ],
                },
            })
            .mockResolvedValueOnce({
                node: {
                    id: "FIELD",
                    options: [option("CASE", "In Review")],
                },
            });
        const client = new SetupProjectClient({ request }, "2026-03-10");

        await expect(client.ensureStatusOption("oauth", "FIELD", "In review"))
            .resolves.toMatchObject({ id: "EXACT", name: "In review" });
        await expect(client.ensureStatusOption("oauth", "FIELD", "IN REVIEW"))
            .resolves.toMatchObject({ id: "CASE", name: "In Review" });
        expect(request).toHaveBeenCalledTimes(2);
    });

    test("adds In review without treating a whitespace difference as a match", async () => {
        const request = vi.fn()
            .mockResolvedValueOnce({
                node: {
                    id: "FIELD",
                    options: [
                        option("TODO", "Todo", "GREEN", "Not started"),
                        option("SPACED", "In  review"),
                    ],
                },
            })
            .mockResolvedValueOnce({
                updateProjectV2Field: {
                    projectV2Field: {
                        id: "FIELD",
                        options: [
                            option("TODO", "Todo", "GREEN", "Not started"),
                            option("SPACED", "In  review"),
                            option("REVIEW", "In review", "ORANGE"),
                        ],
                    },
                },
            });
        const client = new SetupProjectClient({ request }, "2026-03-10");

        await expect(client.ensureStatusOption("oauth", "FIELD", "In review"))
            .resolves.toMatchObject({ id: "REVIEW", name: "In review" });
        expect(request.mock.calls[1]?.[2]).toEqual({
            fieldID: "FIELD",
            options: [
                option("TODO", "Todo", "GREEN", "Not started"),
                option("SPACED", "In  review"),
                { name: "In review", color: "ORANGE", description: "" },
            ],
        });
    });

});

function option(
    id: string,
    name: string,
    color = "ORANGE",
    description = ""
): { id: string; name: string; color: string; description: string } {
    return { id, name, color, description };
}

function githubResponse(body: unknown, init: ResponseInit = {}): Response {
    const headers = new Headers(init.headers);
    headers.set("X-OAuth-Scopes", "project");
    return Response.json(body, { ...init, headers });
}

function graphQL(): GraphQLRequester {
    return { request: vi.fn() } as unknown as GraphQLRequester;
}
