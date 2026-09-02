import { afterEach, describe, expect, test, vi } from "vitest";
import {
    decryptCredentialToken,
    encryptCredentialToken,
    OAuthCredentialProvider,
} from "../src/oauth-credential-provider";

const encryptionKey = btoa(String.fromCharCode(...new Uint8Array(32).fill(7)));
const now = Date.UTC(2026, 8, 2, 12, 0, 0);

afterEach(() => vi.unstubAllGlobals());

describe("OAuth credential encryption", () => {
    test("round trips only with the same credential and token purpose", async () => {
        const envelope = await encryptCredentialToken(
            "credential-1",
            "access",
            "private-access-token",
            encryptionKey
        );

        await expect(decryptCredentialToken(
            "credential-1",
            "access",
            envelope,
            encryptionKey
        )).resolves.toBe("private-access-token");
        await expect(decryptCredentialToken(
            "credential-1",
            "refresh",
            envelope,
            encryptionKey
        )).rejects.toMatchObject({ code: "OAUTH_REAUTH_REQUIRED" });
    });
});

describe("OAuthCredentialProvider", () => {
    test("reuses an active unexpired access token", async () => {
        const database = await databaseWithCredential();
        const provider = makeProvider(database.binding);
        const operation = vi.fn(async () => "result");

        await expect(provider.withValidAccessToken("credential-1", operation)).resolves.toBe("result");
        expect(operation).toHaveBeenCalledWith("old-access-token");
        expect(database.record.credential_version).toBe(1);
    });

    test("refreshes once and retries after a 401", async () => {
        const database = await databaseWithCredential();
        const provider = makeProvider(database.binding);
        vi.stubGlobal("fetch", vi.fn()
            .mockResolvedValueOnce(Response.json({
                access_token: "new-access-token",
                refresh_token: "new-refresh-token",
                expires_in: 28_800,
                refresh_token_expires_in: 15_897_600,
                scope: "project",
            }))
            .mockResolvedValueOnce(Response.json(
                { node_id: "USER_NODE" },
                { headers: { "X-OAuth-Scopes": "project" } }
            )));
        const operation = vi.fn()
            .mockRejectedValueOnce(Object.assign(new Error("unauthorized"), { status: 401 }))
            .mockResolvedValueOnce("result");

        await expect(provider.withValidAccessToken("credential-1", operation)).resolves.toBe("result");
        expect(operation).toHaveBeenNthCalledWith(1, "old-access-token");
        expect(operation).toHaveBeenNthCalledWith(2, "new-access-token");
        expect(database.record.credential_version).toBe(2);
        expect(database.record.health_state).toBe("ACTIVE");
        expect(database.record.granted_scopes).toBe(JSON.stringify(["project"]));
    });

    test("marks a refreshed credential when the actual project scope is missing", async () => {
        const database = await databaseWithCredential();
        const provider = makeProvider(database.binding);
        vi.stubGlobal("fetch", vi.fn()
            .mockResolvedValueOnce(Response.json({
                access_token: "new-access-token",
                refresh_token: "new-refresh-token",
                expires_in: 28_800,
                refresh_token_expires_in: 15_897_600,
                scope: "project",
            }))
            .mockResolvedValueOnce(Response.json(
                { node_id: "USER_NODE" },
                { headers: { "X-OAuth-Scopes": "" } }
            )));
        const operation = vi.fn()
            .mockRejectedValueOnce(Object.assign(new Error("unauthorized"), { status: 401 }));

        await expect(provider.withValidAccessToken("credential-1", operation))
            .rejects.toMatchObject({ code: "OAUTH_SCOPE_MISSING" });
        expect(database.record.credential_version).toBe(2);
        expect(database.record.health_state).toBe("SCOPE_MISSING");
    });

    test("fails closed when the stored project scope is missing", async () => {
        const database = await databaseWithCredential({ granted_scopes: "[]" });
        const provider = makeProvider(database.binding);
        const operation = vi.fn(async () => "result");

        await expect(provider.withValidAccessToken("credential-1", operation))
            .rejects.toMatchObject({ code: "OAUTH_SCOPE_MISSING" });
        expect(operation).not.toHaveBeenCalled();
    });
});

function makeProvider(database: D1Database): OAuthCredentialProvider {
    return new OAuthCredentialProvider(database, {
        clientID: "client-id",
        clientSecret: "client-secret",
        encryptionKey,
        apiVersion: "2026-03-10",
    }, () => now);
}

async function databaseWithCredential(overrides: Record<string, unknown> = {}): Promise<{
    binding: D1Database;
    record: Record<string, unknown>;
}> {
    const record: Record<string, unknown> = {
        id: "credential-1",
        encrypted_access_token: await encryptCredentialToken(
            "credential-1", "access", "old-access-token", encryptionKey
        ),
        encrypted_refresh_token: await encryptCredentialToken(
            "credential-1", "refresh", "old-refresh-token", encryptionKey
        ),
        access_token_expires_at: new Date(now + 60 * 60 * 1000).toISOString(),
        refresh_token_expires_at: new Date(now + 30 * 24 * 60 * 60 * 1000).toISOString(),
        granted_scopes: JSON.stringify(["project"]),
        credential_version: 1,
        health_state: "ACTIVE",
        github_user_node_id: "USER_NODE",
        ...overrides,
    };
    const binding = {
        prepare(sql: string) {
            let values: unknown[] = [];
            const statement = {
                bind(...arguments_: unknown[]) {
                    values = arguments_;
                    return statement;
                },
                async first() {
                    return sql.includes("SELECT credential.id") ? record : null;
                },
                async run() {
                    if (sql.includes("SET health_state = ?")) {
                        record.health_state = values[0];
                    } else if (sql.includes("SET granted_scopes = ?")) {
                        record.granted_scopes = values[0];
                        record.health_state = "ACTIVE";
                    } else if (sql.includes("credential_version = credential_version + 1")) {
                        if (record.credential_version !== values[7]) {
                            return { meta: { changes: 0 } };
                        }
                        record.encrypted_access_token = values[0];
                        record.encrypted_refresh_token = values[1];
                        record.access_token_expires_at = values[2];
                        record.refresh_token_expires_at = values[3];
                        record.granted_scopes = values[4];
                        record.credential_version = Number(record.credential_version) + 1;
                        record.health_state = "ACTIVE";
                    }
                    return { meta: { changes: 1 } };
                },
            };
            return statement;
        },
    } as unknown as D1Database;
    return { binding, record };
}
