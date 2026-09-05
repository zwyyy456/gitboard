import { describe, expect, test } from "vitest";
import type { Env } from "../src/index";
import { handleManagementRequest } from "../src/management-api";

const automationRecord = {
    id: "automation-1",
    oauth_credential_id: "credential-1",
    installation_id: 42,
    project_owner_login: "octocat",
    project_number: 3,
    project_node_id: "PROJECT_NODE",
    enabled: 1,
    health_state: "ACTIVE",
    updated_at: "2026-09-03T00:00:00.000Z",
    delivery_state: "FAILED",
    delivery_error_code: "OAUTH_REAUTH_REQUIRED",
    delivery_received_at: "2026-09-03T00:00:00.000Z",
    installation_status: "ACTIVE",
    credential_health_state: "ACTIVE",
    repository_count: 2,
    private_payload: "must not escape",
};

describe("management API", () => {
    test("authenticates a hashed bearer token and returns only stable status fields", async () => {
        const database = fakeDatabase();
        const response = await handleManagementRequest(
            new Request("https://automation.example/api/automations", {
                headers: { Authorization: "Bearer management-secret" },
            }),
            { DB: database.binding } as Env
        );
        const body = await response.json<{ automations: Array<Record<string, unknown>> }>();

        expect(response.status).toBe(200);
        expect(database.managementTokenHash).not.toBe("management-secret");
        expect(body.automations).toEqual([{
            id: "automation-1",
            accountLogin: "octocat",
            repositoryCount: 2,
            mappingProjectNumber: 3,
            enabled: true,
            healthState: "ACTIVE",
            updatedAt: "2026-09-03T00:00:00.000Z",
            lastDelivery: {
                state: "FAILED",
                errorCode: "OAUTH_REAUTH_REQUIRED",
                receivedAt: "2026-09-03T00:00:00.000Z",
            },
        }]);
    });

    test("deletes the automation and conditionally removes its owned service data", async () => {
        const database = fakeDatabase();
        const response = await handleManagementRequest(
            new Request("https://automation.example/api/automations/automation-1", {
                method: "DELETE",
                headers: { Authorization: "Bearer management-secret" },
            }),
            { DB: database.binding } as Env
        );

        expect(response.status).toBe(204);
        expect(database.batchSQL).toHaveLength(4);
        expect(database.batchSQL[0]).toContain("DELETE FROM project_automations");
        expect(database.batchSQL[1]).toContain("DELETE FROM oauth_credentials");
        expect(database.batchSQL[2]).toContain("DELETE FROM installations");
        expect(database.batchSQL[3]).toContain("DELETE FROM users");
    });

    test("classifies asynchronous management failures", async () => {
        const database = fakeDatabase();
        database.binding.batch = async () => { throw new Error("database unavailable"); };

        const response = await handleManagementRequest(
            new Request("https://automation.example/api/automations/automation-1", {
                method: "DELETE",
                headers: { Authorization: "Bearer management-secret" },
            }),
            { DB: database.binding } as Env
        );

        expect(response.status).toBe(500);
        await expect(response.json()).resolves.toEqual({ error: "MANAGEMENT_UNAVAILABLE" });
    });
});

function fakeDatabase(): {
    binding: D1Database;
    managementTokenHash: string | null;
    batchSQL: string[];
} {
    const state = {
        managementTokenHash: null as string | null,
        batchSQL: [] as string[],
    };
    const binding = {
        prepare(sql: string) {
            let values: unknown[] = [];
            const statement = {
                sql,
                bind(...arguments_: unknown[]) {
                    values = arguments_;
                    return statement;
                },
                async first() {
                    if (sql.includes("FROM management_tokens")) {
                        state.managementTokenHash = String(values[0]);
                        return { token_id: "token-1", user_id: "user-1" };
                    }
                    if (sql.includes("WHERE automation.id = ?")) return automationRecord;
                    return null;
                },
                async all() {
                    return { results: [automationRecord] };
                },
                async run() {
                    return { meta: { changes: 1 } };
                },
            };
            return statement;
        },
        async batch(statements: Array<{ sql: string }>) {
            state.batchSQL = statements.map((statement) => statement.sql);
            return statements.map(() => ({ meta: { changes: 1 } }));
        },
    } as unknown as D1Database;
    return {
        binding,
        get managementTokenHash() { return state.managementTokenHash; },
        get batchSQL() { return state.batchSQL; },
    };
}
