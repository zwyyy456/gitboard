import { beforeAll, expect, test } from "vitest";
import { handleManagementRequest } from "../../src/management-api";
import { runMaintenance } from "../../src/maintenance";
import { persistSetupCompletion } from "../../src/setup-completion";
import { testEnv, initializeDatabase, queueThat, environmentWith, seedConfigurableSetup, completionInput, tokenHash, seedMaintenanceSetup, credentialInsertion, installationInsertion, maintenanceDelivery, maintenanceObjectCounts } from "./runtime-fixtures";

beforeAll(initializeDatabase);

test("maintenance terminates stale work and preserves current setup references", async () => {
    const now = new Date("2026-09-03T00:00:00.000Z");
    const old = "2026-07-01T00:00:00.000Z";
    const stale = "2026-08-01T00:00:00.000Z";
    const recent = "2026-09-02T00:00:00.000Z";
    await seedMaintenanceSetup("protected", 120, "2026-09-04T00:00:00.000Z");
    await seedMaintenanceSetup("abandoned", 121, "2026-09-01T00:00:00.000Z");
    await testEnv.DB.batch([
        maintenanceDelivery("maintenance-completed", "COMPLETED", old, old),
        maintenanceDelivery("maintenance-ignored", "IGNORED", old, old),
        maintenanceDelivery("maintenance-stale", "RETRYING", stale, null),
        maintenanceDelivery("maintenance-recent", "QUEUED", recent, null),
    ]);

    await runMaintenance(testEnv.DB, now);

    const deliveries = await testEnv.DB.prepare(
        `SELECT delivery_id, processing_state, error_code
         FROM webhook_deliveries WHERE delivery_id LIKE 'maintenance-%'`
    ).all<{ delivery_id: string; processing_state: string; error_code: string | null }>();
    const deliveryStates = Object.fromEntries(deliveries.results.map((delivery) => [
        delivery.delivery_id,
        [delivery.processing_state, delivery.error_code],
    ]));
    const protectedCounts = await maintenanceObjectCounts("protected", 120);
    const abandonedCounts = await maintenanceObjectCounts("abandoned", 121);

    expect(deliveryStates).toEqual({
        "maintenance-stale": ["FAILED", "DELIVERY_STALE"],
        "maintenance-recent": ["QUEUED", null],
    });
    expect(protectedCounts).toEqual({ users: 1, credentials: 1, installations: 1, sessions: 1 });
    expect(abandonedCounts).toEqual({ users: 0, credentials: 0, installations: 0, sessions: 0 });
});

test("deleting an automation preserves objects used by an unexpired setup", async () => {
    const now = new Date().toISOString();
    const token = "management-delete-reference";
    await testEnv.DB.batch([
        testEnv.DB.prepare(
            `INSERT INTO users (
                id, github_user_node_id, github_user_database_id, github_login,
                created_at, updated_at
             ) VALUES ('user-delete-reference', 'USER-DELETE-REFERENCE', 122, 'owner', ?, ?)`
        ).bind(now, now),
        credentialInsertion("credential-delete-reference", "user-delete-reference", now),
        installationInsertion(122, "user-delete-reference", now),
        testEnv.DB.prepare(
            `INSERT INTO project_automations (
                id, user_id, oauth_credential_id, installation_id,
                project_owner_login, project_number,
                project_node_id, status_field_node_id, in_progress_option_id,
                in_review_option_id, done_option_id, enabled, health_state,
                created_at, updated_at
             ) VALUES (
                'automation-delete-reference', 'user-delete-reference',
                'credential-delete-reference', 122, 'owner',
                1, 'PROJECT', 'FIELD', 'PROGRESS', 'REVIEW', 'DONE', 1, 'ACTIVE', ?, ?
             )`
        ).bind(now, now),
        testEnv.DB.prepare(
            `INSERT INTO setup_sessions (
                id, setup_token_hash, user_id, oauth_credential_id, installation_id,
                state, expires_at, created_at, updated_at, purpose
             ) VALUES (
                'setup-delete-reference', 'setup-token-delete-reference',
                'user-delete-reference', 'credential-delete-reference', 122,
                'CONFIGURATION_PENDING', ?, ?, ?, 'INITIAL'
             )`
        ).bind(new Date(Date.now() + 60_000).toISOString(), now, now),
        testEnv.DB.prepare(
            `INSERT INTO management_tokens (id, user_id, token_hash, created_at)
             VALUES ('token-delete-reference', 'user-delete-reference', ?, ?)`
        ).bind(await tokenHash(token), now),
    ]);

    const response = await handleManagementRequest(new Request(
        "https://example.invalid/api/automations/automation-delete-reference",
        { method: "DELETE", headers: { Authorization: `Bearer ${token}` } }
    ), environmentWith(queueThat(async () => {})));
    const counts = await maintenanceObjectCounts("delete-reference", 122);

    expect(response.status).toBe(204);
    expect(counts).toEqual({ users: 1, credentials: 1, installations: 1, sessions: 1 });
});

test("deleting the final automation removes its service data and returns success", async () => {
    const token = "management-delete-final";
    const setup = await seedConfigurableSetup("delete-final", 123);
    const automationID = await persistSetupCompletion(
        testEnv.DB,
        completionInput(setup, 1123, token)
    );

    const response = await handleManagementRequest(new Request(
        `https://example.invalid/api/automations/${automationID}`,
        { method: "DELETE", headers: { Authorization: `Bearer ${token}` } }
    ), environmentWith(queueThat(async () => {})));
    const counts = await maintenanceObjectCounts("delete-final", 123);
    const tokenRecord = await testEnv.DB.prepare(
        "SELECT id FROM management_tokens WHERE user_id = 'user-delete-final'"
    ).first<{ id: string }>();

    expect(response.status).toBe(204);
    expect(counts).toEqual({ users: 0, credentials: 0, installations: 0, sessions: 0 });
    expect(tokenRecord).toBeNull();
});
