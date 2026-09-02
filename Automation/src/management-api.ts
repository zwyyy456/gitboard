import type { Env } from "./index";
import { createReauthorizationSession } from "./setup-api";

interface ManagementIdentity {
    token_id: string;
    user_id: string;
}

interface AutomationRecord {
    id: string;
    oauth_credential_id: string;
    installation_id: number;
    repository_id: number;
    repository_name_with_owner: string;
    project_owner_login: string;
    project_number: number;
    project_node_id: string;
    enabled: number;
    health_state: string;
    updated_at: string;
    delivery_state: string | null;
    delivery_error_code: string | null;
    delivery_received_at: string | null;
    installation_status: string;
    credential_health_state: string;
    repository_available: number;
}

export async function handleManagementRequest(request: Request, env: Env): Promise<Response> {
    try {
        const identity = await authenticateManagementRequest(request, env.DB);
        const url = new URL(request.url);
        if (request.method === "GET" && url.pathname === "/api/automations") {
            return listAutomations(identity.user_id, env.DB);
        }
        const match = url.pathname.match(/^\/api\/automations\/([^/]+)(?:\/(reauthorization))?$/);
        if (!match) return new Response("Not found", { status: 404 });
        if (request.method === "PATCH" && !match[2]) {
            return updateAutomation(request, identity.user_id, match[1], env.DB);
        }
        if (request.method === "DELETE" && !match[2]) {
            return deleteAutomation(identity.user_id, match[1], env.DB);
        }
        if (request.method === "POST" && match[2] === "reauthorization") {
            return beginReauthorization(identity.user_id, match[1], env);
        }
        return new Response("Not found", { status: 404 });
    } catch (error) {
        const managementError = error instanceof ManagementRequestError
            ? error
            : new ManagementRequestError(500, "MANAGEMENT_UNAVAILABLE");
        return Response.json(
            { error: managementError.code },
            { status: managementError.status }
        );
    }
}

async function listAutomations(userID: string, database: D1Database): Promise<Response> {
    const result = await database.prepare(
        `SELECT automation.id,
                automation.oauth_credential_id,
                automation.installation_id,
                automation.repository_id,
                automation.repository_name_with_owner,
                automation.project_owner_login,
                automation.project_number,
                automation.project_node_id,
                automation.enabled,
                automation.health_state,
                automation.updated_at,
                installation.status AS installation_status,
                credential.health_state AS credential_health_state,
                EXISTS (
                    SELECT 1 FROM installation_repositories repository
                    WHERE repository.installation_id = automation.installation_id
                      AND repository.repository_id = automation.repository_id
                ) AS repository_available,
                delivery.processing_state AS delivery_state,
                delivery.error_code AS delivery_error_code,
                delivery.received_at AS delivery_received_at
         FROM project_automations automation
         JOIN installations installation
           ON installation.installation_id = automation.installation_id
         JOIN oauth_credentials credential
           ON credential.id = automation.oauth_credential_id
         LEFT JOIN webhook_deliveries delivery
           ON delivery.delivery_id = (
               SELECT latest.delivery_id
               FROM webhook_deliveries latest
               WHERE latest.automation_id = automation.id
               ORDER BY latest.received_at DESC
               LIMIT 1
           )
         WHERE automation.user_id = ?
         ORDER BY automation.created_at`
    ).bind(userID).all<AutomationRecord>();
    return Response.json({ automations: result.results.map(publicAutomation) });
}

async function updateAutomation(
    request: Request,
    userID: string,
    automationID: string,
    database: D1Database
): Promise<Response> {
    const body = await readJSONObject(request);
    if (typeof body.enabled !== "boolean") {
        throw new ManagementRequestError(400, "INVALID_AUTOMATION_UPDATE");
    }
    const automation = await loadAutomation(userID, automationID, database);
    if (body.enabled && !canEnable(automation)) {
        throw new ManagementRequestError(409, "AUTOMATION_NOT_READY");
    }
    const now = new Date().toISOString();
    await database.prepare(
        "UPDATE project_automations SET enabled = ?, updated_at = ? WHERE id = ? AND user_id = ?"
    ).bind(body.enabled ? 1 : 0, now, automationID, userID).run();
    return Response.json({
        automation: publicAutomation({
            ...automation,
            enabled: body.enabled ? 1 : 0,
            updated_at: now,
        }),
    });
}

async function deleteAutomation(
    userID: string,
    automationID: string,
    database: D1Database
): Promise<Response> {
    const automation = await loadAutomation(userID, automationID, database);
    const results = await database.batch([
        database.prepare(
            "DELETE FROM project_automations WHERE id = ? AND user_id = ?"
        ).bind(automationID, userID),
        database.prepare(
            `DELETE FROM oauth_credentials
             WHERE id = ?
               AND NOT EXISTS (
                   SELECT 1 FROM project_automations WHERE oauth_credential_id = ?
               )`
        ).bind(automation.oauth_credential_id, automation.oauth_credential_id),
        database.prepare(
            `DELETE FROM installations
             WHERE installation_id = ?
               AND NOT EXISTS (
                   SELECT 1 FROM project_automations WHERE installation_id = ?
               )`
        ).bind(automation.installation_id, automation.installation_id),
        database.prepare(
            `DELETE FROM users
             WHERE id = ?
               AND NOT EXISTS (
                   SELECT 1 FROM project_automations WHERE user_id = ?
               )`
        ).bind(userID, userID),
    ]);
    if (results[0].meta.changes !== 1) {
        throw new ManagementRequestError(404, "AUTOMATION_NOT_FOUND");
    }
    return new Response(null, { status: 204 });
}

async function beginReauthorization(
    userID: string,
    automationID: string,
    env: Env
): Promise<Response> {
    const automation = await loadAutomation(userID, automationID, env.DB);
    return createReauthorizationSession(
        userID,
        automationID,
        automation.installation_id,
        env
    );
}

async function authenticateManagementRequest(
    request: Request,
    database: D1Database
): Promise<ManagementIdentity> {
    const token = bearerToken(request.headers.get("Authorization"));
    if (!token) throw new ManagementRequestError(401, "MANAGEMENT_AUTH_REQUIRED");
    const identity = await database.prepare(
        `SELECT id AS token_id, user_id
         FROM management_tokens
         WHERE token_hash = ? AND revoked_at IS NULL`
    ).bind(await hashToken(token)).first<ManagementIdentity>();
    if (!identity) throw new ManagementRequestError(401, "MANAGEMENT_AUTH_REQUIRED");
    await database.prepare(
        "UPDATE management_tokens SET last_used_at = ? WHERE id = ?"
    ).bind(new Date().toISOString(), identity.token_id).run();
    return identity;
}

async function loadAutomation(
    userID: string,
    automationID: string,
    database: D1Database
): Promise<AutomationRecord> {
    const automation = await database.prepare(
        `SELECT automation.id,
                automation.oauth_credential_id,
                automation.installation_id,
                automation.repository_id,
                automation.repository_name_with_owner,
                automation.project_owner_login,
                automation.project_number,
                automation.project_node_id,
                automation.enabled,
                automation.health_state,
                automation.updated_at,
                installation.status AS installation_status,
                credential.health_state AS credential_health_state,
                EXISTS (
                    SELECT 1 FROM installation_repositories repository
                    WHERE repository.installation_id = automation.installation_id
                      AND repository.repository_id = automation.repository_id
                ) AS repository_available,
                NULL AS delivery_state,
                NULL AS delivery_error_code,
                NULL AS delivery_received_at
         FROM project_automations automation
         JOIN installations installation
           ON installation.installation_id = automation.installation_id
         JOIN oauth_credentials credential
           ON credential.id = automation.oauth_credential_id
         WHERE automation.id = ? AND automation.user_id = ?`
    ).bind(automationID, userID).first<AutomationRecord>();
    if (!automation) throw new ManagementRequestError(404, "AUTOMATION_NOT_FOUND");
    return automation;
}

function canEnable(automation: AutomationRecord): boolean {
    return automation.installation_status === "ACTIVE"
        && automation.credential_health_state === "ACTIVE"
        && automation.repository_available === 1
        && (automation.health_state === "ACTIVE"
            || automation.health_state === "CONTENT_VISIBILITY_UNVERIFIED");
}

function publicAutomation(automation: AutomationRecord): Record<string, unknown> {
    return {
        id: automation.id,
        repositoryID: automation.repository_id,
        repositoryNameWithOwner: automation.repository_name_with_owner,
        projectOwnerLogin: automation.project_owner_login,
        projectNumber: automation.project_number,
        projectNodeID: automation.project_node_id,
        enabled: automation.enabled === 1,
        healthState: automation.health_state,
        updatedAt: automation.updated_at,
        lastDelivery: automation.delivery_state ? {
            state: automation.delivery_state,
            errorCode: automation.delivery_error_code,
            receivedAt: automation.delivery_received_at,
        } : null,
    };
}

async function readJSONObject(request: Request): Promise<Record<string, unknown>> {
    const text = await request.text();
    if (text.length > 4_096) throw new ManagementRequestError(413, "REQUEST_TOO_LARGE");
    try {
        const value: unknown = JSON.parse(text);
        if (!isRecord(value)) throw new Error();
        return value;
    } catch {
        throw new ManagementRequestError(400, "INVALID_JSON");
    }
}

function bearerToken(header: string | null): string | null {
    return header?.match(/^Bearer ([A-Za-z0-9_-]+)$/)?.[1] ?? null;
}

async function hashToken(value: string): Promise<string> {
    const hash = new Uint8Array(await crypto.subtle.digest(
        "SHA-256", new TextEncoder().encode(value)
    ));
    return btoa(String.fromCharCode(...hash))
        .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
}

class ManagementRequestError extends Error {
    constructor(readonly status: number, readonly code: string) {
        super(code);
    }
}
