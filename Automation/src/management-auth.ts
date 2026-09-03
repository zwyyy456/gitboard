export interface ManagementIdentity {
    tokenID: string;
    userID: string;
}

interface ManagementIdentityRecord {
    token_id: string;
    user_id: string;
}

export class ManagementAuthenticationError extends Error {
    constructor() {
        super("MANAGEMENT_AUTH_REQUIRED");
    }
}

export async function authenticateManagementRequest(
    request: Request,
    database: D1Database
): Promise<ManagementIdentity> {
    const token = request.headers.get("Authorization")
        ?.match(/^Bearer ([A-Za-z0-9_-]+)$/)?.[1];
    if (!token) throw new ManagementAuthenticationError();

    const identity = await database.prepare(
        `SELECT id AS token_id, user_id
         FROM management_tokens
         WHERE token_hash = ? AND revoked_at IS NULL`
    ).bind(await hashToken(token)).first<ManagementIdentityRecord>();
    if (!identity) throw new ManagementAuthenticationError();

    await database.prepare(
        "UPDATE management_tokens SET last_used_at = ? WHERE id = ?"
    ).bind(new Date().toISOString(), identity.token_id).run();
    return { tokenID: identity.token_id, userID: identity.user_id };
}

async function hashToken(value: string): Promise<string> {
    const hash = new Uint8Array(await crypto.subtle.digest(
        "SHA-256", new TextEncoder().encode(value)
    ));
    return btoa(String.fromCharCode(...hash))
        .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}
