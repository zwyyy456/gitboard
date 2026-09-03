import { GitHubAppClient, type InstallationRepository } from "./github-app-client";
import type { Env } from "./index";
import { WebhookRequestError } from "./webhook-receiver";

interface InstallationWebhook {
    action: string;
    installationID: number;
    accountID: number;
    accountType: string;
}

interface UserRecord {
    id: string;
}

const activeActions = new Set(["created", "new_permissions_accepted", "unsuspend"]);

export async function receiveInstallationWebhook(
    eventName: "installation" | "installation_repositories",
    body: ArrayBuffer,
    env: Env
): Promise<Response> {
    const event = parseInstallationWebhook(body);
    if (event.accountType !== "User") {
        return Response.json({ accepted: false, reason: "unsupported_account" }, { status: 202 });
    }

    const user = await env.DB.prepare(
        "SELECT id FROM users WHERE github_user_database_id = ?"
    ).bind(event.accountID).first<UserRecord>();
    if (!user) {
        return Response.json({ accepted: false, reason: "setup_not_started" }, { status: 202 });
    }

    if (eventName === "installation_repositories") {
        if (event.action !== "added" && event.action !== "removed") {
            return Response.json({ accepted: false, reason: "unsupported_action" }, { status: 202 });
        }
        await reconcileRepositories(event.installationID, env);
        return Response.json({ accepted: true }, { status: 202 });
    }

    if (activeActions.has(event.action)) {
        const now = new Date().toISOString();
        await env.DB.prepare(
            `INSERT INTO installations (
                installation_id, user_id, github_account_id, status, updated_at
             ) VALUES (?, ?, ?, 'ACTIVE', ?)
             ON CONFLICT(installation_id) DO UPDATE SET
                user_id = excluded.user_id,
                github_account_id = excluded.github_account_id,
                status = 'ACTIVE',
                updated_at = excluded.updated_at`
        ).bind(event.installationID, user.id, event.accountID, now).run();
        await reconcileRepositories(event.installationID, env);
        return Response.json({ accepted: true }, { status: 202 });
    }

    if (event.action === "suspend" || event.action === "deleted") {
        await deactivateInstallation(event.installationID, event.action.toUpperCase(), env.DB);
        return Response.json({ accepted: true }, { status: 202 });
    }

    return Response.json({ accepted: false, reason: "unsupported_action" }, { status: 202 });
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

async function reconcileRepositories(installationID: number, env: Env): Promise<void> {
    const client = new GitHubAppClient(
        env.GITHUB_APP_ID,
        env.GITHUB_APP_PRIVATE_KEY,
        env.GITHUB_API_VERSION
    );
    const repositories = await client.listInstallationRepositories(installationID);
    await replaceRepositories(env.DB, installationID, repositories);
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
        database.prepare(
            `UPDATE project_automations
             SET enabled = 0,
                 health_state = 'INSTALLATION_REPOSITORY_REMOVED',
                 updated_at = ?
             WHERE installation_id = ?
               AND NOT EXISTS (
                   SELECT 1
                   FROM installation_repositories repository
                   WHERE repository.installation_id = project_automations.installation_id
                     AND repository.repository_id = project_automations.repository_id
               )`
        ).bind(now, installationID),
    ]);
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

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
}

function isPositiveInteger(value: unknown): value is number {
    return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}
