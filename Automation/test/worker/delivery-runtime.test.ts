import { beforeAll, expect, test } from "vitest";
import { AutomationRunner } from "../../src/automation-runner";
import { failExhaustedDelivery, flushDeliveryOutbox, queueDelivery } from "../../src/delivery-outbox";
import { InstallationLifecycleRunner, receiveInstallationWebhook } from "../../src/installation-lifecycle";
import type { DeliveryMessage } from "../../src/index";
import { persistSetupCompletion } from "../../src/setup-completion";
import { receiveGitHubWebhook } from "../../src/webhook-receiver";
import { testEnv, initializeDatabase, queueThat, environmentWith, pullRequestWebhookRequest, deliveryState, seedCompletedAutomationDelivery, seedUser, seedConfigurableSetup, completionInput } from "./runtime-fixtures";

beforeAll(initializeDatabase);

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
        },
        { async publish() {} }
    );

    await expect(runner.run({ deliveryID: "delivery-terminal" }, 2))
        .resolves.toEqual({ action: "ack" });
    expect(truthReads).toBe(0);
    expect(projectWrites).toBe(0);
    await expect(deliveryState("delivery-terminal")).resolves.toBe("COMPLETED");
});

test("accepts pull requests from every repository in the account installation", async () => {
    const setup = await seedConfigurableSetup("account-webhook", 131);
    const automationID = await persistSetupCompletion(
        testEnv.DB,
        completionInput(setup, 1131, "management-account-webhook")
    );
    const now = new Date().toISOString();
    await testEnv.DB.prepare(
        `INSERT INTO installation_repositories (
            installation_id, repository_id, repository_node_id, name_with_owner, updated_at
         ) VALUES (131, 2131, 'REPOSITORY-2131', 'owner/repository-2131', ?)`
    ).bind(now).run();
    const messages: DeliveryMessage[] = [];
    const environment = environmentWith(queueThat(async (message) => { messages.push(message); }));

    const accepted = await receiveGitHubWebhook(
        await pullRequestWebhookRequest("account-repository", 131, 2131),
        environment
    );
    const ignored = await receiveGitHubWebhook(
        await pullRequestWebhookRequest("outside-installation", 131, 999_999),
        environment
    );
    const delivery = await testEnv.DB.prepare(
        `SELECT automation_id, repository_id
         FROM webhook_deliveries WHERE delivery_id = 'account-repository'`
    ).first<{ automation_id: string; repository_id: number }>();

    expect(await accepted.json()).toEqual({ accepted: true });
    expect(await ignored.json()).toEqual({
        accepted: false,
        reason: "automation_not_found",
    });
    expect(delivery).toEqual({ automation_id: automationID, repository_id: 2131 });
    expect(messages).toEqual([{ deliveryID: "account-repository" }]);
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
    }, { async publish() {} });

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
