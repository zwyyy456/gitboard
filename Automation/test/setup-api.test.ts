import { afterEach, describe, expect, test, vi } from "vitest";
import { handleSetupRequest } from "../src/setup-api";
import type { Env } from "../src/index";

afterEach(() => {
    vi.unstubAllGlobals();
});

describe("setup session", () => {
    test("returns the bearer secret once and stores only its hash", async () => {
        let values: unknown[] = [];
        const database = {
            prepare() {
                const statement = {
                    bind(...arguments_: unknown[]) {
                        values = arguments_;
                        return statement;
                    },
                    async run() {
                        return { meta: { changes: 1 } };
                    },
                };
                return statement;
            },
        } as unknown as D1Database;
        const response = await handleSetupRequest(
            new Request("https://automation.example/api/setup/sessions", { method: "POST" }),
            { DB: database, PUBLIC_BASE_URL: "https://automation.example" } as Env
        );
        const body = await response.json<{
            id: string;
            setupToken: string;
            authorizationURL: string;
        }>();

        expect(response.status).toBe(201);
        expect(body.authorizationURL).toBe(
            `https://automation.example/setup/${body.id}/oauth`
        );
        expect(body.setupToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
        expect(values[0]).toBe(body.id);
        expect(values[1]).not.toBe(body.setupToken);
        expect(values[1]).toMatch(/^[A-Za-z0-9_-]{43}$/);
    });

    test("redirects an authorized user to GitHub App installation with the setup cookie", async () => {
        const session = {
            id: "setup-session",
            setup_token_hash: "setup-token-hash",
            user_id: null,
            oauth_credential_id: null,
            installation_id: null,
            state: "OAUTH_PENDING",
            expires_at: "2999-01-01T00:00:00.000Z",
            purpose: "INITIAL",
            automation_id: null,
            management_token_id: null,
        };
        const database = {
            prepare(sql: string) {
                const statement = {
                    bind() {
                        return statement;
                    },
                    async first() {
                        if (sql.includes("FROM setup_sessions")) return session;
                        if (sql.includes("FROM users")) return null;
                        throw new Error(`Unexpected first query: ${sql}`);
                    },
                };
                return statement;
            },
            async batch() {
                return [
                    { meta: { changes: 1 } },
                    { meta: { changes: 1 } },
                    { meta: { changes: 1 } },
                ];
            },
        } as unknown as D1Database;
        const fetchMock = vi.fn()
            .mockResolvedValueOnce(Response.json({
                access_token: "access-token",
                refresh_token: "refresh-token",
                expires_in: 28_800,
                refresh_token_expires_in: 15_897_600,
            }))
            .mockResolvedValueOnce(Response.json({
                id: 1,
                node_id: "USER_NODE",
                login: "owner",
                type: "User",
            }, {
                headers: { "X-OAuth-Scopes": "project" },
            }))
            .mockResolvedValueOnce(new Response(null, { status: 404 }));
        vi.stubGlobal("fetch", fetchMock);

        const response = await handleSetupRequest(
            new Request("https://automation.example/oauth/callback?code=code&state=state"),
            {
                DB: database,
                GITHUB_API_VERSION: "2026-03-10",
                GITHUB_APP_ID: "12345",
                GITHUB_APP_PRIVATE_KEY: await privateKeyPEM(),
                GITHUB_APP_SLUG: "gitboard-automation",
                GITHUB_OAUTH_CLIENT_ID: "oauth-client",
                GITHUB_OAUTH_CLIENT_SECRET: "oauth-secret",
                OAUTH_TOKEN_ENCRYPTION_KEY: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                PUBLIC_BASE_URL: "https://automation.example",
            } as Env
        );

        expect(response.status).toBe(302);
        expect(response.headers.get("Location")).toBe(
            "https://github.com/apps/gitboard-automation/installations/new"
        );
        expect(response.headers.get("Set-Cookie")).toContain("gb_setup=setup-session");
    });

    test("reuses an existing personal installation after OAuth", async () => {
        const session: {
            id: string;
            setup_token_hash: string;
            user_id: string | null;
            oauth_credential_id: string | null;
            installation_id: number | null;
            state: string;
            expires_at: string;
            purpose: string;
            automation_id: string | null;
            management_token_id: string | null;
        } = {
            id: "existing-installation-session",
            setup_token_hash: "setup-token-hash",
            user_id: null,
            oauth_credential_id: null,
            installation_id: null,
            state: "OAUTH_PENDING",
            expires_at: "2999-01-01T00:00:00.000Z",
            purpose: "INITIAL",
            automation_id: null,
            management_token_id: null,
        };
        let installationUpdate: unknown[] | null = null;
        let batchCount = 0;
        const database = {
            prepare(sql: string) {
                let values: unknown[] = [];
                const statement = {
                    bind(...arguments_: unknown[]) {
                        values = arguments_;
                        return statement;
                    },
                    async first() {
                        if (sql.includes("FROM setup_sessions")) return session;
                        if (sql.includes("SELECT id FROM users")) return null;
                        if (sql.includes("SELECT github_user_database_id")) {
                            return { github_user_database_id: 1 };
                        }
                        throw new Error(`Unexpected first query: ${sql}`);
                    },
                    async run() {
                        if (sql.includes("UPDATE setup_sessions")
                            && sql.includes("SET installation_id")) {
                            installationUpdate = values;
                        }
                        return { meta: { changes: 1 } };
                    },
                };
                return statement;
            },
            async batch(statements: unknown[]) {
                batchCount += 1;
                if (batchCount === 1) {
                    session.user_id = "user-id";
                    session.oauth_credential_id = "credential-id";
                    session.state = "INSTALLATION_PENDING";
                }
                return statements.map(() => ({ meta: { changes: 1 } }));
            },
        } as unknown as D1Database;
        const fetchMock = vi.fn()
            .mockResolvedValueOnce(Response.json({
                access_token: "access-token",
                refresh_token: "refresh-token",
                expires_in: 28_800,
                refresh_token_expires_in: 15_897_600,
            }))
            .mockResolvedValueOnce(Response.json({
                id: 1,
                node_id: "USER_NODE",
                login: "owner",
                type: "User",
            }, {
                headers: { "X-OAuth-Scopes": "project" },
            }))
            .mockResolvedValueOnce(Response.json({
                id: 9,
                account: { id: 1, type: "User" },
                suspended_at: null,
            }))
            .mockResolvedValueOnce(Response.json({
                id: 9,
                account: { id: 1, type: "User" },
                suspended_at: null,
            }))
            .mockResolvedValueOnce(Response.json({ token: "installation-token" }))
            .mockResolvedValueOnce(Response.json({
                repositories: [{
                    id: 7,
                    node_id: "REPOSITORY_NODE",
                    full_name: "owner/repository",
                }],
            }));
        vi.stubGlobal("fetch", fetchMock);

        const response = await handleSetupRequest(
            new Request("https://automation.example/oauth/callback?code=code&state=state"),
            {
                DB: database,
                GITHUB_API_VERSION: "2026-03-10",
                GITHUB_APP_ID: "12345",
                GITHUB_APP_PRIVATE_KEY: await privateKeyPEM(),
                GITHUB_APP_SLUG: "gitboard-automation",
                GITHUB_OAUTH_CLIENT_ID: "oauth-client",
                GITHUB_OAUTH_CLIENT_SECRET: "oauth-secret",
                OAUTH_TOKEN_ENCRYPTION_KEY: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                PUBLIC_BASE_URL: "https://automation.example",
            } as Env
        );

        expect(response.status).toBe(302);
        expect(response.headers.get("Location")).toBe(
            "https://automation.example/setup/github-app?installation_id=9"
        );
        expect(response.headers.get("Set-Cookie")).toContain(
            "gb_setup=existing-installation-session"
        );
        expect(fetchMock.mock.calls[2]?.[0]).toBe(
            "https://api.github.com/users/owner/installation"
        );

        const callbackResponse = await handleSetupRequest(new Request(
            response.headers.get("Location")!,
            { headers: { Cookie: response.headers.get("Set-Cookie")! } }
        ), {
            DB: database,
            GITHUB_API_VERSION: "2026-03-10",
            GITHUB_APP_ID: "12345",
            GITHUB_APP_PRIVATE_KEY: await privateKeyPEM(),
            OAUTH_TOKEN_ENCRYPTION_KEY: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            PUBLIC_BASE_URL: "https://automation.example",
        } as Env);

        expect(callbackResponse.status).toBe(200);
        await expect(callbackResponse.text()).resolves.toContain("GitBoard is connected");
        expect(installationUpdate?.[0]).toBe(9);
    });

    test("classifies asynchronous setup failures instead of rejecting the request", async () => {
        const response = await handleSetupRequest(
            new Request("https://automation.example/oauth/callback"),
            {} as Env
        );

        expect(response.status).toBe(400);
        await expect(response.json()).resolves.toEqual({ error: "INVALID_OAUTH_CALLBACK" });
    });

    test("accepts a legacy completion retry without a review selection", async () => {
        const managementToken = "m".repeat(43);
        const session = {
            id: "optional-review-session",
            setup_token_hash: "unused-by-fake-database",
            user_id: "user-id",
            oauth_credential_id: "credential-id",
            installation_id: 9,
            state: "COMPLETE",
            expires_at: "2999-01-01T00:00:00.000Z",
            purpose: "INITIAL",
            automation_id: "automation-id",
            management_token_id: "management-token-id",
            github_login: "owner",
        };
        const completed = {
            state: "COMPLETE",
            automation_id: "automation-id",
            management_token_id: "management-token-id",
            token_hash: await sha256Base64URL(managementToken),
            installation_id: 9,
            project_node_id: "PROJECT",
            project_number: 1,
            status_field_node_id: "STATUS",
            in_progress_option_id: "IN_PROGRESS",
            in_review_option_id: "IN_PROGRESS",
            done_option_id: "DONE",
            review_status_policy: "ENSURE_IN_REVIEW",
        };
        const database = {
            prepare(sql: string) {
                const statement = {
                    bind() {
                        return statement;
                    },
                    async first() {
                        if (sql.includes("LEFT JOIN project_automations")) return completed;
                        if (sql.includes("FROM setup_sessions session")) return session;
                        throw new Error(`Unexpected first query: ${sql}`);
                    },
                };
                return statement;
            },
        } as unknown as D1Database;
        const response = await handleSetupRequest(
            new Request(
                "https://automation.example/api/setup/sessions/optional-review-session/complete",
                {
                    method: "POST",
                    headers: {
                        Authorization: "Bearer setup-token",
                        "Content-Type": "application/json",
                    },
                    body: JSON.stringify({
                        projectNodeID: "PROJECT",
                        projectNumber: 1,
                        statusFieldNodeID: "STATUS",
                        inProgressOptionID: "IN_PROGRESS",
                        doneOptionID: "DONE",
                        managementToken,
                    }),
                }
            ),
            { DB: database } as Env
        );

        expect(response.status).toBe(200);
        await expect(response.json()).resolves.toEqual({ automationID: "automation-id" });
    });
});

async function sha256Base64URL(value: string): Promise<string> {
    const hash = new Uint8Array(await crypto.subtle.digest(
        "SHA-256",
        new TextEncoder().encode(value)
    ));
    return btoa(String.fromCharCode(...hash))
        .replace(/=/g, "")
        .replace(/\+/g, "-")
        .replace(/\//g, "_");
}

async function privateKeyPEM(): Promise<string> {
    const keyPair = await crypto.subtle.generateKey(
        {
            name: "RSASSA-PKCS1-v1_5",
            modulusLength: 2048,
            publicExponent: new Uint8Array([1, 0, 1]),
            hash: "SHA-256",
        },
        true,
        ["sign", "verify"]
    );
    const value = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keyPair.privateKey));
    return `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...value))}\n-----END PRIVATE KEY-----`;
}
