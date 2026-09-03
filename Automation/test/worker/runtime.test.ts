import { env } from "cloudflare:workers";
import { applyD1Migrations, type D1Migration } from "cloudflare:test";
import { beforeAll, expect, test } from "vitest";
import { AutomationRunner } from "../../src/automation-runner";
import {
    failExhaustedDelivery,
    flushDeliveryOutbox,
    queueDelivery,
} from "../../src/delivery-outbox";
import {
    InstallationLifecycleRunner,
    receiveInstallationWebhook,
} from "../../src/installation-lifecycle";
import { handleManagementRequest } from "../../src/management-api";
import { runMaintenance } from "../../src/maintenance";
import type { DeliveryMessage } from "../../src/index";
import type { Env } from "../../src/index";
import { handleSetupRequest, persistSetupCompletion } from "../../src/setup-api";

interface TestEnvironment extends Env {
    TEST_MIGRATIONS: D1Migration[];
}

const testEnv = env as TestEnvironment;

beforeAll(async () => {
    await applyD1Migrations(testEnv.DB, testEnv.TEST_MIGRATIONS);
});

test("starts with the current D1 schema", async () => {
    const tables = await testEnv.DB.prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table'"
    ).all<{ name: string }>();
    const repositoryColumns = await testEnv.DB.prepare(
        "PRAGMA table_info(installation_repositories)"
    ).all<{ name: string }>();
    const setupColumns = await testEnv.DB.prepare(
        "PRAGMA table_info(setup_sessions)"
    ).all<{ name: string }>();

    expect(tables.results.map((table) => table.name)).toContain("project_automations");
    expect(repositoryColumns.results.map((column) => column.name))
        .toContain("repository_node_id");
    expect(setupColumns.results.map((column) => column.name))
        .not.toContain("exchange_code_hash");
});

test("keeps a received delivery when Queue send fails and schedules it again", async () => {
    const now = new Date().toISOString();
    await testEnv.DB.prepare(
        `INSERT INTO webhook_deliveries (
            delivery_id, installation_id, event_name, event_action,
            processing_state, received_at, state_updated_at
         ) VALUES ('delivery-outbox', 7, 'installation', 'created', 'RECEIVED', ?, ?)`
    ).bind(now, now).run();

    const failed = await queueDelivery(
        testEnv.DB,
        queueThat(async () => { throw new Error("unavailable"); }),
        "delivery-outbox"
    );
    const afterFailure = await deliveryState("delivery-outbox");
    const messages: DeliveryMessage[] = [];

    await flushDeliveryOutbox(
        testEnv.DB,
        queueThat(async (message) => { messages.push(message); })
    );

    expect(failed).toBe(false);
    expect(afterFailure).toBe("RECEIVED");
    expect(messages).toEqual([{ deliveryID: "delivery-outbox" }]);
    await expect(deliveryState("delivery-outbox")).resolves.toBe("QUEUED");
});

test("does not run GitHub work for a terminal delivery", async () => {
    await seedCompletedAutomationDelivery();
    let truthReads = 0;
    let projectWrites = 0;
    const runner = new AutomationRunner(
        testEnv.DB,
        {
            async loadWorkflowTruth() {
                truthReads += 1;
                return [];
            },
        },
        {
            async applyStatuses() {
                projectWrites += 1;
                return {};
            },
        }
    );

    await expect(runner.run({ deliveryID: "delivery-terminal" }, 2))
        .resolves.toEqual({ action: "ack" });
    expect(truthReads).toBe(0);
    expect(projectWrites).toBe(0);
    await expect(deliveryState("delivery-terminal")).resolves.toBe("COMPLETED");
});

test("persists an installation webhook before doing GitHub work", async () => {
    await seedUser();
    const messages: DeliveryMessage[] = [];
    const queue = queueThat(async (message) => { messages.push(message); });
    const body = new TextEncoder().encode(JSON.stringify({
        action: "created",
        installation: { id: 17, account: { id: 1, type: "User" } },
    })).buffer;

    const response = await receiveInstallationWebhook(
        "installation",
        "installation-ingress",
        body,
        environmentWith(queue)
    );
    const delivery = await testEnv.DB.prepare(
        `SELECT event_name, processing_state
         FROM webhook_deliveries WHERE delivery_id = 'installation-ingress'`
    ).first<{ event_name: string; processing_state: string }>();

    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({ accepted: true });
    expect(messages).toEqual([{ deliveryID: "installation-ingress" }]);
    expect(delivery).toEqual({ event_name: "installation", processing_state: "QUEUED" });
});

test("uses current suspended installation truth instead of an older event action", async () => {
    const now = new Date().toISOString();
    await seedUser();
    await testEnv.DB.batch([
        testEnv.DB.prepare(
            `INSERT INTO installations (
                installation_id, user_id, github_account_id, status, updated_at
             ) VALUES (27, 'user', 1, 'ACTIVE', ?)`
        ).bind(now),
        testEnv.DB.prepare(
            `INSERT INTO installation_repositories (
                installation_id, repository_id, repository_node_id, name_with_owner, updated_at
             ) VALUES (27, 11, 'OLD_REPOSITORY', 'owner/old', ?)`
        ).bind(now),
        testEnv.DB.prepare(
            `INSERT INTO webhook_deliveries (
                delivery_id, installation_id, event_name, event_action,
                processing_state, received_at, state_updated_at
             ) VALUES (
                'installation-stale-event', 27, 'installation', 'unsuspend', 'QUEUED', ?, ?
             )`
        ).bind(now, now),
    ]);
    let repositoryReads = 0;
    const runner = new InstallationLifecycleRunner(testEnv.DB, {
        async getInstallation() {
            return {
                id: 27,
                accountID: 1,
                accountType: "User",
                status: "SUSPENDED" as const,
            };
        },
        async listInstallationRepositories() {
            repositoryReads += 1;
            return [];
        },
    });

    await expect(runner.run("installation-stale-event", 1))
        .resolves.toEqual({ action: "ack" });
    const installation = await testEnv.DB.prepare(
        "SELECT status FROM installations WHERE installation_id = 27"
    ).first<{ status: string }>();
    const repositories = await testEnv.DB.prepare(
        "SELECT COUNT(*) AS count FROM installation_repositories WHERE installation_id = 27"
    ).first<{ count: number }>();

    expect(installation?.status).toBe("SUSPENDED");
    expect(repositories?.count).toBe(0);
    expect(repositoryReads).toBe(0);
    await expect(deliveryState("installation-stale-event")).resolves.toBe("COMPLETED");
});

test("fails every nonterminal DLQ state without overwriting terminal deliveries", async () => {
    const now = new Date().toISOString();
    const states = [
        "RECEIVED",
        "QUEUED",
        "PROCESSING",
        "RETRYING",
        "COMPLETED",
        "FAILED",
        "IGNORED",
    ];
    for (const state of states) {
        await testEnv.DB.prepare(
            `INSERT INTO webhook_deliveries (
                delivery_id, installation_id, event_name, event_action,
                processing_state, error_code, received_at, state_updated_at
             ) VALUES (?, 99, 'installation', 'created', ?, ?, ?, ?)`
        ).bind(
            `dlq-${state}`,
            state,
            state === "RETRYING" ? "TRANSIENT_GITHUB_FAILURE" : null,
            now,
            now
        ).run();
        await failExhaustedDelivery(testEnv.DB, `dlq-${state}`);
    }

    const deliveries = await testEnv.DB.prepare(
        `SELECT delivery_id, processing_state, error_code
         FROM webhook_deliveries WHERE delivery_id LIKE 'dlq-%'`
    ).all<{ delivery_id: string; processing_state: string; error_code: string | null }>();
    const result = Object.fromEntries(deliveries.results.map((delivery) => [
        delivery.delivery_id,
        [delivery.processing_state, delivery.error_code],
    ]));

    expect(result).toEqual({
        "dlq-RECEIVED": ["FAILED", "RETRIES_EXHAUSTED"],
        "dlq-QUEUED": ["FAILED", "RETRIES_EXHAUSTED"],
        "dlq-PROCESSING": ["FAILED", "RETRIES_EXHAUSTED"],
        "dlq-RETRYING": ["FAILED", "TRANSIENT_GITHUB_FAILURE"],
        "dlq-COMPLETED": ["COMPLETED", null],
        "dlq-FAILED": ["FAILED", null],
        "dlq-IGNORED": ["IGNORED", null],
    });
});

test("completes one setup idempotently without duplicating its token or automation", async () => {
    const setup = await seedConfigurableSetup("idempotent", 107);
    const input = completionInput(setup, 1107, "management-idempotent");

    const first = await persistSetupCompletion(testEnv.DB, input);
    const second = await persistSetupCompletion(testEnv.DB, input);
    const counts = await setupCompletionCounts("idempotent");

    expect(second).toBe(first);
    expect(counts).toEqual({ automations: 1, tokens: 1 });
});

test("binds an add-automation setup session to the existing management identity", async () => {
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
        purpose: "ADD",
        user_id: "user-add-session",
        management_token_id: "token-add-session",
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

test("rolls back a management token when the source repository is already configured", async () => {
    const setup = await seedConfigurableSetup("source-conflict", 109);
    const now = new Date().toISOString();
    await testEnv.DB.prepare(
        `INSERT INTO project_automations (
            id, user_id, oauth_credential_id, installation_id, repository_id,
            repository_name_with_owner, project_owner_login, project_number,
            project_node_id, status_field_node_id, in_progress_option_id,
            in_review_option_id, done_option_id, enabled, health_state,
            created_at, updated_at
         ) VALUES (
            'existing-source-conflict', 'user-source-conflict', 'credential-source-conflict',
            109, 1109, 'owner/source-conflict-1109', 'owner', 1, 'OLD_PROJECT',
            'OLD_FIELD', 'OLD_PROGRESS', 'OLD_REVIEW', 'OLD_DONE', 1, 'ACTIVE', ?, ?
         )`
    ).bind(now, now).run();

    await expect(persistSetupCompletion(
        testEnv.DB,
        completionInput(setup, 1109, "management-source-conflict")
    )).rejects.toThrow("SOURCE_REPOSITORY_ALREADY_CONFIGURED");
    const token = await testEnv.DB.prepare(
        "SELECT id FROM management_tokens WHERE user_id = 'user-source-conflict'"
    ).first<{ id: string }>();
    const session = await testEnv.DB.prepare(
        "SELECT state FROM setup_sessions WHERE id = 'setup-source-conflict'"
    ).first<{ state: string }>();

    expect(token).toBeNull();
    expect(session?.state).toBe("CONFIGURATION_PENDING");
});

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
                id, user_id, oauth_credential_id, installation_id, repository_id,
                repository_name_with_owner, project_owner_login, project_number,
                project_node_id, status_field_node_id, in_progress_option_id,
                in_review_option_id, done_option_id, enabled, health_state,
                created_at, updated_at
             ) VALUES (
                'automation-delete-reference', 'user-delete-reference',
                'credential-delete-reference', 122, 1122, 'owner/repository', 'owner',
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
                'CONFIGURATION_PENDING', ?, ?, ?, 'ADD'
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

function queueThat(
    send: (message: DeliveryMessage) => Promise<void>
): Queue<DeliveryMessage> {
    return { send } as unknown as Queue<DeliveryMessage>;
}

function environmentWith(queue: Queue<DeliveryMessage>): Env {
    return {
        DB: testEnv.DB,
        AUTOMATION_QUEUE: queue,
        GITHUB_API_VERSION: "2026-03-10",
        GITHUB_APP_ID: "unused",
        GITHUB_APP_PRIVATE_KEY: "unused",
        GITHUB_OAUTH_CLIENT_ID: "unused",
        GITHUB_OAUTH_CLIENT_SECRET: "unused",
        GITHUB_APP_SLUG: "unused",
        GITHUB_WEBHOOK_SECRET: "unused",
        OAUTH_TOKEN_ENCRYPTION_KEY: "unused",
        PUBLIC_BASE_URL: "https://example.invalid",
    };
}

async function deliveryState(deliveryID: string): Promise<string | null> {
    const delivery = await testEnv.DB.prepare(
        "SELECT processing_state FROM webhook_deliveries WHERE delivery_id = ?"
    ).bind(deliveryID).first<{ processing_state: string }>();
    return delivery?.processing_state ?? null;
}

async function seedCompletedAutomationDelivery(): Promise<void> {
    const now = new Date().toISOString();
    await testEnv.DB.batch([
        userInsertion(now),
        testEnv.DB.prepare(
            `INSERT INTO oauth_credentials (
                id, user_id, encrypted_access_token, encrypted_refresh_token,
                access_token_expires_at, refresh_token_expires_at, granted_scopes,
                credential_version, health_state, updated_at
             ) VALUES (
                'credential', 'user', 'access', 'refresh', ?, ?, '["project"]', 1, 'ACTIVE', ?
             )`
        ).bind(now, now, now),
        testEnv.DB.prepare(
            `INSERT INTO installations (
                installation_id, user_id, github_account_id, status, updated_at
             ) VALUES (7, 'user', 1, 'ACTIVE', ?)`
        ).bind(now),
        testEnv.DB.prepare(
            `INSERT INTO installation_repositories (
                installation_id, repository_id, repository_node_id, name_with_owner, updated_at
             ) VALUES (7, 11, 'REPOSITORY_NODE', 'owner/repository', ?)`
        ).bind(now),
        testEnv.DB.prepare(
            `INSERT INTO project_automations (
                id, user_id, oauth_credential_id, installation_id, repository_id,
                repository_name_with_owner, project_owner_login, project_number,
                project_node_id, status_field_node_id, in_progress_option_id,
                in_review_option_id, done_option_id, enabled, health_state,
                created_at, updated_at
             ) VALUES (
                'automation', 'user', 'credential', 7, 11, 'owner/repository',
                'owner', 1, 'PROJECT', 'FIELD', 'PROGRESS', 'REVIEW', 'DONE',
                1, 'ACTIVE', ?, ?
             )`
        ).bind(now, now),
        testEnv.DB.prepare(
            `INSERT INTO webhook_deliveries (
                delivery_id, automation_id, installation_id, repository_id,
                pull_request_number, event_name, event_action, processing_state,
                received_at, state_updated_at, completed_at
             ) VALUES (
                'delivery-terminal', 'automation', 7, 11, 42, 'pull_request',
                'closed', 'COMPLETED', ?, ?, ?
             )`
        ).bind(now, now, now),
    ]);
}

async function seedUser(): Promise<void> {
    const now = new Date().toISOString();
    await userInsertion(now).run();
}

function userInsertion(now: string): D1PreparedStatement {
    return testEnv.DB.prepare(
        `INSERT OR IGNORE INTO users (
            id, github_user_node_id, github_user_database_id, github_login, created_at, updated_at
         ) VALUES ('user', 'USER_NODE', 1, 'owner', ?, ?)`
    ).bind(now, now);
}

async function seedConfigurableSetup(suffix: string, installationID: number) {
    const now = new Date().toISOString();
    const userID = `user-${suffix}`;
    const credentialID = `credential-${suffix}`;
    const sessionID = `setup-${suffix}`;
    await testEnv.DB.batch([
        testEnv.DB.prepare(
            `INSERT INTO users (
                id, github_user_node_id, github_user_database_id, github_login,
                created_at, updated_at
             ) VALUES (?, ?, ?, 'owner', ?, ?)`
        ).bind(userID, `USER-${suffix}`, installationID, now, now),
        testEnv.DB.prepare(
            `INSERT INTO oauth_credentials (
                id, user_id, encrypted_access_token, encrypted_refresh_token,
                access_token_expires_at, refresh_token_expires_at, granted_scopes,
                credential_version, health_state, updated_at
             ) VALUES (?, ?, 'access', 'refresh', ?, ?, '["project"]', 1, 'ACTIVE', ?)`
        ).bind(credentialID, userID, now, now, now),
        testEnv.DB.prepare(
            `INSERT INTO installations (
                installation_id, user_id, github_account_id, status, updated_at
             ) VALUES (?, ?, ?, 'ACTIVE', ?)`
        ).bind(installationID, userID, installationID, now),
        testEnv.DB.prepare(
            `INSERT INTO setup_sessions (
                id, setup_token_hash, user_id, oauth_credential_id, installation_id,
                state, expires_at, created_at, updated_at, purpose
             ) VALUES (?, ?, ?, ?, ?, 'CONFIGURATION_PENDING', ?, ?, ?, 'INITIAL')`
        ).bind(
            sessionID, `setup-token-${suffix}`, userID, credentialID, installationID,
            new Date(Date.now() + 60_000).toISOString(), now, now
        ),
    ]);
    return {
        id: sessionID,
        setup_token_hash: `setup-token-${suffix}`,
        user_id: userID,
        oauth_credential_id: credentialID,
        installation_id: installationID,
        state: "CONFIGURATION_PENDING" as const,
        expires_at: new Date(Date.now() + 60_000).toISOString(),
        purpose: "INITIAL" as const,
        management_token_id: null,
    };
}

function completionInput(
    session: Awaited<ReturnType<typeof seedConfigurableSetup>>,
    repositoryID: number,
    managementToken: string
) {
    return {
        session,
        selection: {
            sourceRepositoryID: repositoryID,
            projectNodeID: `PROJECT-${repositoryID}`,
            projectNumber: repositoryID,
            statusFieldNodeID: `FIELD-${repositoryID}`,
            inProgressOptionID: `PROGRESS-${repositoryID}`,
            inReviewOptionID: `REVIEW-${repositoryID}`,
            doneOptionID: `DONE-${repositoryID}`,
        },
        managementToken,
        repositoryNameWithOwner: `owner/repository-${repositoryID}`,
        projectOwnerLogin: "owner",
        healthState: "ACTIVE" as const,
    };
}

async function setupCompletionCounts(suffix: string) {
    const userID = `user-${suffix}`;
    const result = await testEnv.DB.prepare(
        `SELECT
            (SELECT COUNT(*) FROM project_automations WHERE user_id = ?) AS automations,
            (SELECT COUNT(*) FROM management_tokens WHERE user_id = ?) AS tokens`
    ).bind(userID, userID).first<{ automations: number; tokens: number }>();
    return result ?? { automations: 0, tokens: 0 };
}

async function tokenHash(value: string): Promise<string> {
    const hash = new Uint8Array(await crypto.subtle.digest(
        "SHA-256", new TextEncoder().encode(value)
    ));
    return btoa(String.fromCharCode(...hash))
        .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

async function seedMaintenanceSetup(
    suffix: string,
    installationID: number,
    expiresAt: string
): Promise<void> {
    const now = "2026-08-01T00:00:00.000Z";
    await testEnv.DB.batch([
        testEnv.DB.prepare(
            `INSERT INTO users (
                id, github_user_node_id, github_user_database_id, github_login,
                created_at, updated_at
             ) VALUES (?, ?, ?, 'owner', ?, ?)`
        ).bind(`user-${suffix}`, `USER-${suffix}`, installationID, now, now),
        credentialInsertion(`credential-${suffix}`, `user-${suffix}`, now),
        installationInsertion(installationID, `user-${suffix}`, now),
        testEnv.DB.prepare(
            `INSERT INTO setup_sessions (
                id, setup_token_hash, user_id, oauth_credential_id, installation_id,
                state, expires_at, created_at, updated_at, purpose
             ) VALUES (?, ?, ?, ?, ?, 'INSTALLATION_PENDING', ?, ?, ?, 'INITIAL')`
        ).bind(
            `setup-${suffix}`, `setup-token-${suffix}`, `user-${suffix}`,
            `credential-${suffix}`, installationID, expiresAt, now, now
        ),
    ]);
}

function credentialInsertion(id: string, userID: string, now: string): D1PreparedStatement {
    return testEnv.DB.prepare(
        `INSERT INTO oauth_credentials (
            id, user_id, encrypted_access_token, encrypted_refresh_token,
            access_token_expires_at, refresh_token_expires_at, granted_scopes,
            credential_version, health_state, updated_at
         ) VALUES (?, ?, 'access', 'refresh', ?, ?, '["project"]', 1, 'ACTIVE', ?)`
    ).bind(id, userID, now, now, now);
}

function installationInsertion(
    installationID: number,
    userID: string,
    now: string
): D1PreparedStatement {
    return testEnv.DB.prepare(
        `INSERT INTO installations (
            installation_id, user_id, github_account_id, status, updated_at
         ) VALUES (?, ?, ?, 'ACTIVE', ?)`
    ).bind(installationID, userID, installationID, now);
}

function maintenanceDelivery(
    id: string,
    state: string,
    stateUpdatedAt: string,
    completedAt: string | null
): D1PreparedStatement {
    return testEnv.DB.prepare(
        `INSERT INTO webhook_deliveries (
            delivery_id, installation_id, event_name, event_action, processing_state,
            received_at, state_updated_at, completed_at
         ) VALUES (?, 999, 'installation', 'created', ?, ?, ?, ?)`
    ).bind(id, state, stateUpdatedAt, stateUpdatedAt, completedAt);
}

async function maintenanceObjectCounts(suffix: string, installationID: number) {
    const result = await testEnv.DB.prepare(
        `SELECT
            (SELECT COUNT(*) FROM users WHERE id = ?) AS users,
            (SELECT COUNT(*) FROM oauth_credentials WHERE id = ?) AS credentials,
            (SELECT COUNT(*) FROM installations WHERE installation_id = ?) AS installations,
            (SELECT COUNT(*) FROM setup_sessions WHERE id = ?) AS sessions`
    ).bind(
        `user-${suffix}`,
        `credential-${suffix}`,
        installationID,
        `setup-${suffix}`
    ).first<{
        users: number;
        credentials: number;
        installations: number;
        sessions: number;
    }>();
    return result ?? { users: 0, credentials: 0, installations: 0, sessions: 0 };
}
