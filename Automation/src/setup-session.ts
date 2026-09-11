import type { Env } from "./index";

const setupLifetimeMilliseconds = 30 * 60 * 1000;

export type SetupState = "OAUTH_PENDING" | "INSTALLATION_PENDING" | "CONFIGURATION_PENDING" | "RECOVERY_PENDING" | "COMPLETE";

export interface SetupSessionRecord {
    id: string;
    setup_token_hash: string;
    user_id: string | null;
    oauth_credential_id: string | null;
    installation_id: number | null;
    state: SetupState;
    expires_at: string;
    purpose?: "INITIAL" | "REAUTHORIZE";
    automation_id?: string | null;
    management_token_id?: string | null;
    github_user_database_id?: number;
    github_login?: string;
}

export async function createSetupSession(_request: Request, env: Env): Promise<Response> {
    const id = crypto.randomUUID();
    const setupToken = randomToken();
    const now = new Date();
    const expiresAt = new Date(now.getTime() + setupLifetimeMilliseconds).toISOString();
    await env.DB.prepare(
        `INSERT INTO setup_sessions (
            id, setup_token_hash, user_id, management_token_id, purpose,
            state, expires_at, created_at, updated_at
         ) VALUES (?, ?, ?, ?, ?, 'OAUTH_PENDING', ?, ?, ?)`
    ).bind(
        id,
        await hashToken(setupToken),
        null,
        null,
        "INITIAL",
        expiresAt,
        now.toISOString(),
        now.toISOString()
    ).run();
    return Response.json({
        id,
        setupToken,
        authorizationURL: `${publicBaseURL(env)}/setup/${id}/oauth`,
        expiresAt,
    }, { status: 201 });
}

export async function createReauthorizationSession(
    userID: string,
    automationID: string,
    installationID: number,
    env: Env
): Promise<Response> {
    const id = crypto.randomUUID();
    const setupToken = randomToken();
    const now = new Date();
    const expiresAt = new Date(now.getTime() + setupLifetimeMilliseconds).toISOString();
    const result = await env.DB.prepare(
        `INSERT INTO setup_sessions (
            id, setup_token_hash, user_id, oauth_credential_id, installation_id,
            state, expires_at, created_at, updated_at, purpose, automation_id
         )
         SELECT ?, ?, ?, oauth_credential_id, ?, 'OAUTH_PENDING', ?, ?, ?,
                'REAUTHORIZE', id
         FROM project_automations
         WHERE id = ? AND user_id = ?`
    ).bind(
        id, await hashToken(setupToken), userID, installationID,
        expiresAt, now.toISOString(), now.toISOString(), automationID, userID
    ).run();
    if (result.meta.changes !== 1) throw new SetupRequestError(404, "AUTOMATION_NOT_FOUND");
    return Response.json({
        id,
        setupToken,
        authorizationURL: `${publicBaseURL(env)}/setup/${id}/oauth`,
        expiresAt,
    }, { status: 201 });
}

export async function authenticateSetupSession(
    request: Request,
    sessionID: string,
    database: D1Database
): Promise<SetupSessionRecord> {
    const token = bearerToken(request.headers.get("Authorization"));
    if (!token) throw new SetupRequestError(401, "SETUP_AUTH_REQUIRED");
    const session = await database.prepare(
        `SELECT session.id, session.setup_token_hash, session.user_id,
                session.oauth_credential_id, session.installation_id,
                session.state, session.expires_at, session.purpose,
                session.automation_id, session.management_token_id,
                user.github_login
         FROM setup_sessions session
         LEFT JOIN users user ON user.id = session.user_id
         WHERE session.id = ? AND session.setup_token_hash = ?`
    ).bind(sessionID, await hashToken(token)).first<SetupSessionRecord>();
    if (!session) throw new SetupRequestError(401, "SETUP_AUTH_REQUIRED");
    requireNotExpired(session);
    return session;
}

export async function loadSession(database: D1Database, sessionID: string): Promise<SetupSessionRecord> {
    const session = await database.prepare(
        `SELECT id, setup_token_hash, user_id, oauth_credential_id, installation_id,
                state, expires_at, purpose, automation_id, management_token_id
         FROM setup_sessions WHERE id = ?`
    ).bind(sessionID).first<SetupSessionRecord>();
    if (!session) throw new SetupRequestError(404, "SETUP_NOT_FOUND");
    requireNotExpired(session);
    return session;
}

export function requireConfigurationContext(session: SetupSessionRecord): {
    userID: string;
    credentialID: string;
    installationID: number;
} {
    if (!session.user_id || !session.oauth_credential_id || !session.installation_id) {
        throw new SetupRequestError(409, "SETUP_STATE_CHANGED");
    }
    return {
        userID: session.user_id,
        credentialID: session.oauth_credential_id,
        installationID: session.installation_id,
    };
}

export function requireState(session: SetupSessionRecord, state: SetupState): void {
    requireNotExpired(session);
    if (session.state !== state) throw new SetupRequestError(409, "SETUP_STATE_CHANGED");
}

function requireNotExpired(session: SetupSessionRecord): void {
    if (Date.parse(session.expires_at) <= Date.now()) {
        throw new SetupRequestError(410, "SETUP_EXPIRED");
    }
}

export async function readJSONObject(request: Request): Promise<Record<string, unknown>> {
    const text = await request.text();
    if (text.length > 16_384) throw new SetupRequestError(413, "REQUEST_TOO_LARGE");
    try {
        const value: unknown = JSON.parse(text);
        if (!isRecord(value)) throw new Error();
        return value;
    } catch {
        throw new SetupRequestError(400, "INVALID_JSON");
    }
}

export function publicSession(session: SetupSessionRecord): Record<string, unknown> {
    return { id: session.id, state: session.state, expiresAt: session.expires_at };
}

export function publicBaseURL(env: Env): string {
    const url = new URL(env.PUBLIC_BASE_URL);
    return url.toString().replace(/\/$/, "");
}

function bearerToken(header: string | null): string | null {
    const match = header?.match(/^Bearer ([A-Za-z0-9_-]+)$/);
    return match?.[1] ?? null;
}

export function randomToken(): string {
    return base64URL(crypto.getRandomValues(new Uint8Array(32)));
}

export async function hashToken(value: string): Promise<string> {
    return base64URL(new Uint8Array(await crypto.subtle.digest(
        "SHA-256", new TextEncoder().encode(value)
    )));
}

function base64URL(value: Uint8Array): string {
    return btoa(String.fromCharCode(...value))
        .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

export function secretToken(value: unknown): string | null {
    return typeof value === "string" && /^[A-Za-z0-9_-]{43}$/.test(value) ? value : null;
}

export function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
}

export class SetupRequestError extends Error {
    constructor(readonly status: number, readonly code: string) {
        super(code);
    }
}

export function positiveInteger(value: unknown): number | null {
    const number = typeof value === "string" && /^\d+$/.test(value) ? Number(value) : value;
    return typeof number === "number" && Number.isSafeInteger(number) && number > 0 ? number : null;
}

