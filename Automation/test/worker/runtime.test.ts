import { env } from "cloudflare:workers";
import { applyD1Migrations, type D1Migration } from "cloudflare:test";
import { beforeAll, expect, test } from "vitest";
import { AutomationRunner } from "../../src/automation-runner";
import { flushDeliveryOutbox, queueDelivery } from "../../src/delivery-outbox";
import type { DeliveryMessage } from "../../src/index";
import type { Env } from "../../src/index";

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

    expect(tables.results.map((table) => table.name)).toContain("project_automations");
    expect(repositoryColumns.results.map((column) => column.name))
        .toContain("repository_node_id");
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

function queueThat(
    send: (message: DeliveryMessage) => Promise<void>
): Queue<DeliveryMessage> {
    return { send } as unknown as Queue<DeliveryMessage>;
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
        testEnv.DB.prepare(
            `INSERT INTO users (
                id, github_user_node_id, github_user_database_id, github_login, created_at, updated_at
             ) VALUES ('user', 'USER_NODE', 1, 'owner', ?, ?)`
        ).bind(now, now),
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
