import type { RunnerDecision } from "./automation-runner";
import { queueDelivery } from "./delivery-outbox";
import {
    GitHubAppRequestError,
    type GitHubInstallation,
    type InstallationRepository,
} from "./github-app-client";
import type { Env } from "./index";
import { WebhookRequestError } from "./webhook-receiver";

type InstallationEventName = "installation" | "installation_repositories";

interface InstallationWebhook {
    action: string;
    installationID: number;
    accountID: number;
    accountType: string;
}

interface UserRecord {
    id: string;
}

interface DeliveryRecord {
    processing_state: string;
    installation_id: number;
}

interface InstallationClient {
    getInstallation(installationID: number): Promise<GitHubInstallation>;
    listInstallationRepositories(installationID: number): Promise<InstallationRepository[]>;
}

const activeActions = new Set(["created", "new_permissions_accepted", "unsuspend"]);
const terminalDeliveryStates = new Set(["COMPLETED", "FAILED", "IGNORED"]);

export async function receiveInstallationWebhook(
    eventName: InstallationEventName,
    deliveryID: string,
    body: ArrayBuffer,
    env: Env
): Promise<Response> {
    const event = parseInstallationWebhook(body);
    if (event.accountType !== "User") {
        return Response.json({ accepted: false, reason: "unsupported_account" }, { status: 202 });
    }
    if (!isSupportedAction(eventName, event.action)) {
        return Response.json({ accepted: false, reason: "unsupported_action" }, { status: 202 });
    }

    const user = await env.DB.prepare(
        "SELECT id FROM users WHERE github_user_database_id = ?"
    ).bind(event.accountID).first<UserRecord>();
    if (!user) {
        return Response.json({ accepted: false, reason: "setup_not_started" }, { status: 202 });
    }

    const now = new Date().toISOString();
    const insertion = await env.DB.prepare(
        `INSERT OR IGNORE INTO webhook_deliveries (
            delivery_id, installation_id, event_name, event_action,
            processing_state, attempt_count, received_at, state_updated_at
         ) VALUES (?, ?, ?, ?, 'RECEIVED', 0, ?, ?)`
    ).bind(deliveryID, event.installationID, eventName, event.action, now, now).run();

    if (insertion.meta.changes === 0) {
        const existing = await env.DB.prepare(
            "SELECT processing_state FROM webhook_deliveries WHERE delivery_id = ?"
        ).bind(deliveryID).first<{ processing_state: string }>();
        if (existing?.processing_state !== "RECEIVED") {
            return Response.json({ accepted: true, duplicate: true }, { status: 202 });
        }
    }

    const queued = await queueDelivery(env.DB, env.AUTOMATION_QUEUE, deliveryID);
    console.info("installation_delivery_persisted", { deliveryID, queued });
    return Response.json({ accepted: true }, { status: 202 });
}

export class InstallationLifecycleRunner {
    constructor(
        private readonly database: D1Database,
        private readonly client: InstallationClient
    ) {}

    async run(deliveryID: string, attempt: number): Promise<RunnerDecision> {
        const delivery = await this.database.prepare(
            `SELECT processing_state, installation_id
             FROM webhook_deliveries
             WHERE delivery_id = ?
               AND event_name IN ('installation', 'installation_repositories')`
        ).bind(deliveryID).first<DeliveryRecord>();
        if (!delivery || terminalDeliveryStates.has(delivery.processing_state)) {
            return { action: "ack" };
        }

        const started = await this.database.prepare(
            `UPDATE webhook_deliveries
             SET processing_state = 'PROCESSING',
                 attempt_count = attempt_count + 1,
                 state_updated_at = ?
             WHERE delivery_id = ?
               AND processing_state NOT IN ('COMPLETED', 'FAILED', 'IGNORED')`
        ).bind(new Date().toISOString(), deliveryID).run();
        if (started.meta.changes !== 1) return { action: "ack" };

        try {
            await this.reconcile(delivery.installation_id);
            await this.finish(deliveryID, "COMPLETED", null);
            return { action: "ack" };
        } catch (error) {
            if (!(error instanceof GitHubAppRequestError) || error.retryable) {
                await this.retry(deliveryID);
                return { action: "retry", delaySeconds: retryDelay(attempt) };
            }
            await this.finish(deliveryID, "FAILED", "INSTALLATION_RECONCILIATION_FAILED");
            return { action: "ack" };
        }
    }

    private async reconcile(installationID: number): Promise<void> {
        let installation: GitHubInstallation;
        try {
            installation = await this.client.getInstallation(installationID);
        } catch (error) {
            if (error instanceof GitHubAppRequestError && error.status === 404) {
                await deactivateInstallation(installationID, "DELETED", this.database);
                return;
            }
            throw error;
        }

        if (installation.accountType !== "User") {
            await deactivateInstallation(installationID, "ACCOUNT_UNSUPPORTED", this.database);
            return;
        }
        const user = await this.database.prepare(
            "SELECT id FROM users WHERE github_user_database_id = ?"
        ).bind(installation.accountID).first<UserRecord>();
        if (!user) {
            await deactivateInstallation(installationID, "ACCOUNT_MISMATCH", this.database);
            return;
        }

        await upsertInstallation(this.database, installation, user.id);
        if (installation.status === "SUSPENDED") {
            await deactivateInstallation(installationID, "SUSPENDED", this.database);
            return;
        }

        try {
            const repositories = await this.client.listInstallationRepositories(installationID);
            await replaceRepositories(this.database, installationID, repositories);
        } catch (error) {
            if (error instanceof GitHubAppRequestError && error.status === 404) {
                await deactivateInstallation(installationID, "DELETED", this.database);
                return;
            }
            throw error;
        }
    }

    private async retry(deliveryID: string): Promise<void> {
        await this.database.prepare(
            `UPDATE webhook_deliveries
             SET processing_state = 'RETRYING',
                 error_code = 'TRANSIENT_GITHUB_FAILURE',
                 state_updated_at = ?
             WHERE delivery_id = ?
               AND processing_state NOT IN ('COMPLETED', 'FAILED', 'IGNORED')`
        ).bind(new Date().toISOString(), deliveryID).run();
    }

    private async finish(
        deliveryID: string,
        state: "COMPLETED" | "FAILED",
        errorCode: string | null
    ): Promise<void> {
        const now = new Date().toISOString();
        await this.database.prepare(
            `UPDATE webhook_deliveries
             SET processing_state = ?, error_code = ?, completed_at = ?, state_updated_at = ?
             WHERE delivery_id = ?
               AND processing_state NOT IN ('COMPLETED', 'FAILED', 'IGNORED')`
        ).bind(state, errorCode, now, now, deliveryID).run();
    }
}

export function parseInstallationWebhook(body: ArrayBuffer): InstallationWebhook {
    let value: unknown;
    try {
        value = JSON.parse(new TextDecoder().decode(body));
    } catch {
        throw new WebhookRequestError(400, "INVALID_WEBHOOK_PAYLOAD");
    }
    if (!isRecord(value)
        || typeof value.action !== "string"
        || !isRecord(value.installation)
        || !isPositiveInteger(value.installation.id)
        || !isRecord(value.installation.account)
        || !isPositiveInteger(value.installation.account.id)
        || typeof value.installation.account.type !== "string") {
        throw new WebhookRequestError(400, "INVALID_WEBHOOK_PAYLOAD");
    }
    return {
        action: value.action,
        installationID: value.installation.id,
        accountID: value.installation.account.id,
        accountType: value.installation.account.type,
    };
}

export async function replaceRepositories(
    database: D1Database,
    installationID: number,
    repositories: InstallationRepository[]
): Promise<void> {
    const now = new Date().toISOString();
    const encodedRepositories = JSON.stringify(repositories.map((repository) => ({
        id: repository.id,
        nodeID: repository.nodeID,
        name: repository.nameWithOwner,
    })));
    await database.batch([
        database.prepare(
            "DELETE FROM installation_repositories WHERE installation_id = ?"
        ).bind(installationID),
        database.prepare(
            `INSERT INTO installation_repositories (
                installation_id, repository_id, repository_node_id, name_with_owner, updated_at
             )
             SELECT ?,
                    CAST(json_extract(value, '$.id') AS INTEGER),
                    CAST(json_extract(value, '$.nodeID') AS TEXT),
                    CAST(json_extract(value, '$.name') AS TEXT),
                    ?
             FROM json_each(?)`
        ).bind(installationID, now, encodedRepositories),
    ]);
}

async function upsertInstallation(
    database: D1Database,
    installation: GitHubInstallation,
    userID: string
): Promise<void> {
    await database.prepare(
        `INSERT INTO installations (
            installation_id, user_id, github_account_id, status, updated_at
         ) VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(installation_id) DO UPDATE SET
            user_id = excluded.user_id,
            github_account_id = excluded.github_account_id,
            status = excluded.status,
            updated_at = excluded.updated_at`
    ).bind(
        installation.id,
        userID,
        installation.accountID,
        installation.status,
        new Date().toISOString()
    ).run();
}

async function deactivateInstallation(
    installationID: number,
    status: string,
    database: D1Database
): Promise<void> {
    const now = new Date().toISOString();
    await database.batch([
        database.prepare(
            "UPDATE installations SET status = ?, updated_at = ? WHERE installation_id = ?"
        ).bind(status, now, installationID),
        database.prepare(
            "DELETE FROM installation_repositories WHERE installation_id = ?"
        ).bind(installationID),
        database.prepare(
            `UPDATE project_automations
             SET enabled = 0, health_state = ?, updated_at = ?
             WHERE installation_id = ?`
        ).bind(`INSTALLATION_${status}`, now, installationID),
    ]);
}

function isSupportedAction(eventName: InstallationEventName, action: string): boolean {
    if (eventName === "installation_repositories") {
        return action === "added" || action === "removed";
    }
    return activeActions.has(action) || action === "suspend" || action === "deleted";
}

function retryDelay(attempt: number): number {
    return Math.min(60 * 2 ** Math.max(0, attempt - 1), 3_600);
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
}

function isPositiveInteger(value: unknown): value is number {
    return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}
