import { beforeAll, expect, test } from "vitest";
import { handleManagementRequest } from "../../src/management-api";
import { handleSetupRequest } from "../../src/setup-api";
import { persistSetupCompletion } from "../../src/setup-completion";
import { testEnv, initializeDatabase, queueThat, environmentWith, seedConfigurableSetup, completionInput, setupCompletionCounts, tokenHash } from "./runtime-fixtures";

beforeAll(initializeDatabase);

test("recovers an existing account only from a verified setup, preserving mapping and pause state", async () => {
    const setup = await seedConfigurableSetup("recovery", 951);
    const automationID = await persistSetupCompletion(testEnv.DB, completionInput(setup, 1951, "old-recovery-token"));
    await testEnv.DB.prepare("UPDATE project_automations SET enabled = 0 WHERE id = ?").bind(automationID).run();
    const before = await testEnv.DB.prepare("SELECT project_node_id, status_field_node_id, in_progress_option_id, done_option_id, review_status_policy, enabled FROM project_automations WHERE id = ?")
        .bind(automationID).first();
    const secret = "recovery-session-secret";
    const now = new Date().toISOString();
    await testEnv.DB.prepare(
        `INSERT INTO setup_sessions (id, setup_token_hash, user_id, oauth_credential_id,
            installation_id, state, expires_at, created_at, updated_at, purpose)
         VALUES ('recover-session', ?, ?, ?, 951, 'OAUTH_PENDING', ?, ?, ?, 'INITIAL')`
    ).bind(await tokenHash(secret), setup.user_id, setup.oauth_credential_id,
        new Date(Date.now() + 60_000).toISOString(), now, now).run();
    const managementToken = "r".repeat(43);
    const request = (method: string, suffix = "", bearer = secret) => new Request(
        `https://example.invalid/api/setup/sessions/recover-session${suffix}`, {
            method,
            headers: { Authorization: `Bearer ${bearer}`, "Content-Type": "application/json" },
            ...(method === "POST" ? { body: JSON.stringify({ managementToken }) } : {}),
        }
    );
    expect((await handleSetupRequest(request("POST", "/recover", "wrong"), testEnv)).status).toBe(401);
    expect((await handleSetupRequest(request("POST", "/recover"), testEnv)).status).toBe(409);
    await testEnv.DB.prepare("UPDATE setup_sessions SET state = 'CONFIGURATION_PENDING' WHERE id = 'recover-session'").run();
    const status = await handleSetupRequest(request("GET"), testEnv);
    expect(await status.json()).toMatchObject({ state: "RECOVERY_PENDING" });
    expect((await handleSetupRequest(request("POST", "/complete"), testEnv)).status).toBe(409);
    for (let attempt = 0; attempt < 2; attempt++) {
        const response = await handleSetupRequest(request("POST", "/recover"), testEnv);
        expect(response.status).toBe(200);
        expect(await response.json()).toEqual({ automationID });
    }
    expect(await setupCompletionCounts("recovery")).toEqual({ automations: 1, tokens: 2 });
    expect(await testEnv.DB.prepare("SELECT project_node_id, status_field_node_id, in_progress_option_id, done_option_id, review_status_policy, enabled FROM project_automations WHERE id = ?")
        .bind(automationID).first()).toEqual(before);
    const managed = await handleManagementRequest(new Request("https://example.invalid/api/automations", {
        headers: { Authorization: `Bearer ${managementToken}` },
    }), testEnv);
    expect(managed.status).toBe(200);
    expect(await managed.json()).toMatchObject({ automations: [{ id: automationID, enabled: false }] });
});

test("does not grant recovery access to a different account", async () => {
    const owner = await seedConfigurableSetup("recovery-owner", 952);
    const other = await seedConfigurableSetup("recovery-other", 953);
    const automationID = await persistSetupCompletion(testEnv.DB, completionInput(owner, 1952, "owner-token"));
    await testEnv.DB.prepare(
        "UPDATE setup_sessions SET state = 'RECOVERY_PENDING', automation_id = ?, installation_id = 952, setup_token_hash = ? WHERE id = ?"
    ).bind(automationID, await tokenHash("other-secret"), other.id).run();
    const response = await handleSetupRequest(new Request(`https://example.invalid/api/setup/sessions/${other.id}/recover`, {
        method: "POST",
        headers: { Authorization: "Bearer other-secret", "Content-Type": "application/json" },
        body: JSON.stringify({ managementToken: "s".repeat(43) }),
    }), testEnv);
    expect(response.status).toBe(409);
    expect(await setupCompletionCounts("recovery-other")).toEqual({ automations: 0, tokens: 0 });
});

test("completes one setup idempotently without duplicating its token or automation", async () => {
    const setup = await seedConfigurableSetup("idempotent", 107);
    const input = completionInput(
        setup,
        1107,
        "management-idempotent",
        "ENSURE_IN_REVIEW"
    );

    const first = await persistSetupCompletion(testEnv.DB, input);
    const second = await persistSetupCompletion(testEnv.DB, input);
    const counts = await setupCompletionCounts("idempotent");
    const automation = await testEnv.DB.prepare(
        "SELECT review_status_policy FROM project_automations WHERE id = ?"
    ).bind(first).first<{ review_status_policy: string }>();

    expect(second).toBe(first);
    expect(counts).toEqual({ automations: 1, tokens: 1 });
    expect(automation?.review_status_policy).toBe("ENSURE_IN_REVIEW");
});

test("always starts one account-level setup instead of an add-automation flow", async () => {
    const now = new Date().toISOString();
    await testEnv.DB.batch([
        testEnv.DB.prepare(
            `INSERT INTO users (
                id, github_user_node_id, github_user_database_id, github_login,
                created_at, updated_at
             ) VALUES ('user-add-session', 'USER-ADD-SESSION', 110, 'owner', ?, ?)`
        ).bind(now, now),
        testEnv.DB.prepare(
            `INSERT INTO management_tokens (id, user_id, token_hash, created_at)
             VALUES ('token-add-session', 'user-add-session', ?, ?)`
        ).bind(await tokenHash("management-add-session"), now),
    ]);

    const response = await handleSetupRequest(new Request(
        "https://example.invalid/api/setup/sessions",
        {
            method: "POST",
            headers: { Authorization: "Bearer management-add-session" },
        }
    ), environmentWith(queueThat(async () => {})));
    const body = await response.json<{ id: string }>();
    const session = await testEnv.DB.prepare(
        `SELECT purpose, user_id, management_token_id
         FROM setup_sessions WHERE id = ?`
    ).bind(body.id).first<{
        purpose: string;
        user_id: string;
        management_token_id: string;
    }>();

    expect(response.status).toBe(201);
    expect(session).toEqual({
        purpose: "INITIAL",
        user_id: null,
        management_token_id: null,
    });
});

test("allows only one selection when the same setup is completed concurrently", async () => {
    const setup = await seedConfigurableSetup("concurrent", 108);
    const attempts = await Promise.allSettled([
        persistSetupCompletion(
            testEnv.DB,
            completionInput(setup, 1108, "management-concurrent")
        ),
        persistSetupCompletion(
            testEnv.DB,
            completionInput(setup, 2108, "management-concurrent")
        ),
    ]);
    const counts = await setupCompletionCounts("concurrent");

    expect(attempts.filter((attempt) => attempt.status === "fulfilled")).toHaveLength(1);
    expect(counts).toEqual({ automations: 1, tokens: 1 });
});

test("rolls back a management token when the account automation already exists", async () => {
    const setup = await seedConfigurableSetup("source-conflict", 109);
    const now = new Date().toISOString();
    await testEnv.DB.prepare(
        `INSERT INTO project_automations (
            id, user_id, oauth_credential_id, installation_id,
            project_owner_login, project_number,
            project_node_id, status_field_node_id, in_progress_option_id,
            in_review_option_id, done_option_id, enabled, health_state,
            created_at, updated_at
         ) VALUES (
            'existing-source-conflict', 'user-source-conflict', 'credential-source-conflict',
            109, 'owner', 1, 'OLD_PROJECT',
            'OLD_FIELD', 'OLD_PROGRESS', 'OLD_REVIEW', 'OLD_DONE', 1, 'ACTIVE', ?, ?
         )`
    ).bind(now, now).run();

    await expect(persistSetupCompletion(
        testEnv.DB,
        completionInput(setup, 1109, "management-source-conflict")
    )).rejects.toThrow("ACCOUNT_AUTOMATION_ALREADY_CONFIGURED");
    const token = await testEnv.DB.prepare(
        "SELECT id FROM management_tokens WHERE user_id = 'user-source-conflict'"
    ).first<{ id: string }>();
    const session = await testEnv.DB.prepare(
        "SELECT state FROM setup_sessions WHERE id = 'setup-source-conflict'"
    ).first<{ state: string }>();

    expect(token).toBeNull();
    expect(session?.state).toBe("CONFIGURATION_PENDING");
});
