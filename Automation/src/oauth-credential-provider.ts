const githubTokenEndpoint = "https://github.com/login/oauth/access_token";
const githubUserEndpoint = "https://api.github.com/user";
const expiryBufferMilliseconds = 5 * 60 * 1000;

export type OAuthCredentialErrorCode =
    | "OAUTH_REAUTH_REQUIRED"
    | "OAUTH_SCOPE_MISSING"
    | "TRANSIENT_GITHUB_FAILURE";

export class OAuthCredentialError extends Error {
    constructor(readonly code: OAuthCredentialErrorCode) {
        super(code);
    }
}

export interface AccessTokenProvider {
    withValidAccessToken<T>(
        credentialID: string,
        operation: (accessToken: string) => Promise<T>
    ): Promise<T>;
}

interface CredentialRecord {
    id: string;
    encrypted_access_token: string;
    encrypted_refresh_token: string;
    access_token_expires_at: string;
    refresh_token_expires_at: string;
    granted_scopes: string;
    credential_version: number;
    health_state: "ACTIVE" | "REAUTHORIZATION_REQUIRED" | "SCOPE_MISSING" | "REVOKED";
    github_user_node_id: string;
}

export interface OAuthProviderConfiguration {
    clientID: string;
    clientSecret: string;
    encryptionKey: string;
    apiVersion: string;
}

interface RefreshedCredential {
    accessToken: string;
    refreshToken: string;
    accessTokenExpiresAt: string;
    refreshTokenExpiresAt: string;
    scopes: string[];
}

export class OAuthCredentialProvider implements AccessTokenProvider {
    constructor(
        private readonly database: D1Database,
        private readonly configuration: OAuthProviderConfiguration,
        private readonly now: () => number = Date.now
    ) {}

    async withValidAccessToken<T>(
        credentialID: string,
        operation: (accessToken: string) => Promise<T>
    ): Promise<T> {
        let credential = await this.loadCredential(credentialID);
        await this.requireActiveCredential(credential);

        let accessToken: string;
        if (this.expiresWithinBuffer(credential.access_token_expires_at)) {
            const refreshed = await this.refreshCredential(credential);
            credential = refreshed.record;
            accessToken = refreshed.accessToken;
        } else {
            accessToken = await decryptCredentialToken(
                credential.id,
                "access",
                credential.encrypted_access_token,
                this.configuration.encryptionKey
            );
        }

        try {
            return await operation(accessToken);
        } catch (error) {
            if (!isUnauthorized(error)) {
                throw error;
            }
        }

        const refreshed = await this.refreshCredential(credential);
        try {
            return await operation(refreshed.accessToken);
        } catch (error) {
            if (isUnauthorized(error)) {
                await this.setHealthState(credential.id, "REVOKED");
                throw new OAuthCredentialError("OAUTH_REAUTH_REQUIRED");
            }
            throw error;
        }
    }

    private async loadCredential(credentialID: string): Promise<CredentialRecord> {
        const record = await this.database.prepare(
            `SELECT credential.id,
                    credential.encrypted_access_token,
                    credential.encrypted_refresh_token,
                    credential.access_token_expires_at,
                    credential.refresh_token_expires_at,
                    credential.granted_scopes,
                    credential.credential_version,
                    credential.health_state,
                    user.github_user_node_id
             FROM oauth_credentials credential
             JOIN users user ON user.id = credential.user_id
             WHERE credential.id = ?`
        ).bind(credentialID).first<CredentialRecord>();
        if (!record) {
            throw new OAuthCredentialError("OAUTH_REAUTH_REQUIRED");
        }
        return record;
    }

    private async requireActiveCredential(credential: CredentialRecord): Promise<void> {
        if (credential.health_state === "SCOPE_MISSING") {
            throw new OAuthCredentialError("OAUTH_SCOPE_MISSING");
        }
        if (credential.health_state !== "ACTIVE") {
            throw new OAuthCredentialError("OAUTH_REAUTH_REQUIRED");
        }
        const scopes = decodeScopes(credential.granted_scopes);
        if (!scopes.includes("project")) {
            await this.setHealthState(credential.id, "SCOPE_MISSING");
            throw new OAuthCredentialError("OAUTH_SCOPE_MISSING");
        }
    }

    private async refreshCredential(
        credential: CredentialRecord
    ): Promise<{ record: CredentialRecord; accessToken: string }> {
        if (this.isExpired(credential.refresh_token_expires_at)) {
            await this.setHealthState(credential.id, "REAUTHORIZATION_REQUIRED");
            throw new OAuthCredentialError("OAUTH_REAUTH_REQUIRED");
        }
        const refreshToken = await decryptCredentialToken(
            credential.id,
            "refresh",
            credential.encrypted_refresh_token,
            this.configuration.encryptionKey
        );
        let refreshed: RefreshedCredential;
        try {
            refreshed = await this.requestTokenRefresh(refreshToken);
        } catch (error) {
            if (error instanceof OAuthCredentialError
                && error.code === "OAUTH_REAUTH_REQUIRED") {
                await this.setHealthState(credential.id, "REAUTHORIZATION_REQUIRED");
            }
            throw error;
        }
        const encrypted = await this.saveRefreshedCredential(credential, refreshed);
        const record: CredentialRecord = {
            ...credential,
            encrypted_access_token: encrypted.accessToken,
            encrypted_refresh_token: encrypted.refreshToken,
            access_token_expires_at: refreshed.accessTokenExpiresAt,
            refresh_token_expires_at: refreshed.refreshTokenExpiresAt,
            granted_scopes: JSON.stringify(refreshed.scopes),
            credential_version: credential.credential_version + 1,
            health_state: "ACTIVE",
        };
        const validatedScopes = await this.validateIdentityAndScopes(
            refreshed.accessToken,
            credential.github_user_node_id,
            credential.id
        );
        await this.saveValidatedScopes(credential.id, validatedScopes);
        record.granted_scopes = JSON.stringify(validatedScopes);
        return {
            accessToken: refreshed.accessToken,
            record,
        };
    }

    private async requestTokenRefresh(refreshToken: string): Promise<RefreshedCredential> {
        let response: Response;
        try {
            response = await fetch(githubTokenEndpoint, {
                method: "POST",
                headers: {
                    Accept: "application/json",
                    "Content-Type": "application/x-www-form-urlencoded",
                },
                body: new URLSearchParams({
                    client_id: this.configuration.clientID,
                    client_secret: this.configuration.clientSecret,
                    grant_type: "refresh_token",
                    refresh_token: refreshToken,
                }),
            });
        } catch {
            throw new OAuthCredentialError("TRANSIENT_GITHUB_FAILURE");
        }
        if (!response.ok) {
            if (response.status === 400 || response.status === 401) {
                throw new OAuthCredentialError("OAUTH_REAUTH_REQUIRED");
            }
            throw new OAuthCredentialError("TRANSIENT_GITHUB_FAILURE");
        }

        let body: unknown;
        try {
            body = await response.json();
        } catch {
            throw new OAuthCredentialError("TRANSIENT_GITHUB_FAILURE");
        }
        if (!isRecord(body)
            || typeof body.access_token !== "string"
            || typeof body.refresh_token !== "string"
            || !isPositiveNumber(body.expires_in)
            || !isPositiveNumber(body.refresh_token_expires_in)
            || typeof body.scope !== "string") {
            throw new OAuthCredentialError("OAUTH_REAUTH_REQUIRED");
        }
        const now = this.now();
        return {
            accessToken: body.access_token,
            refreshToken: body.refresh_token,
            accessTokenExpiresAt: new Date(now + body.expires_in * 1000).toISOString(),
            refreshTokenExpiresAt: new Date(now + body.refresh_token_expires_in * 1000).toISOString(),
            scopes: parseScopeHeader(body.scope),
        };
    }

    private async validateIdentityAndScopes(
        accessToken: string,
        expectedUserNodeID: string,
        credentialID: string
    ): Promise<string[]> {
        let response: Response;
        try {
            response = await fetch(githubUserEndpoint, {
                headers: {
                    Accept: "application/vnd.github+json",
                    Authorization: `Bearer ${accessToken}`,
                    "User-Agent": "GitBoard-Automation",
                    "X-GitHub-Api-Version": this.configuration.apiVersion,
                },
            });
        } catch {
            throw new OAuthCredentialError("TRANSIENT_GITHUB_FAILURE");
        }
        if (response.status === 401) {
            await this.setHealthState(credentialID, "REVOKED");
            throw new OAuthCredentialError("OAUTH_REAUTH_REQUIRED");
        }
        if (!response.ok) {
            throw new OAuthCredentialError("TRANSIENT_GITHUB_FAILURE");
        }

        const scopes = parseScopeHeader(response.headers.get("X-OAuth-Scopes"));
        if (!scopes.includes("project")) {
            await this.setHealthState(credentialID, "SCOPE_MISSING");
            throw new OAuthCredentialError("OAUTH_SCOPE_MISSING");
        }
        let body: unknown;
        try {
            body = await response.json();
        } catch {
            throw new OAuthCredentialError("TRANSIENT_GITHUB_FAILURE");
        }
        if (!isRecord(body) || body.node_id !== expectedUserNodeID) {
            await this.setHealthState(credentialID, "REAUTHORIZATION_REQUIRED");
            throw new OAuthCredentialError("OAUTH_REAUTH_REQUIRED");
        }
        return scopes;
    }

    private async saveRefreshedCredential(
        credential: CredentialRecord,
        refreshed: RefreshedCredential
    ): Promise<{ accessToken: string; refreshToken: string }> {
        const encryptedAccessToken = await encryptCredentialToken(
            credential.id,
            "access",
            refreshed.accessToken,
            this.configuration.encryptionKey
        );
        const encryptedRefreshToken = await encryptCredentialToken(
            credential.id,
            "refresh",
            refreshed.refreshToken,
            this.configuration.encryptionKey
        );
        const result = await this.database.prepare(
            `UPDATE oauth_credentials
             SET encrypted_access_token = ?,
                 encrypted_refresh_token = ?,
                 access_token_expires_at = ?,
                 refresh_token_expires_at = ?,
                 granted_scopes = ?,
                 credential_version = credential_version + 1,
                 health_state = 'ACTIVE',
                 updated_at = ?
             WHERE id = ? AND credential_version = ?`
        ).bind(
            encryptedAccessToken,
            encryptedRefreshToken,
            refreshed.accessTokenExpiresAt,
            refreshed.refreshTokenExpiresAt,
            JSON.stringify(refreshed.scopes),
            new Date(this.now()).toISOString(),
            credential.id,
            credential.credential_version
        ).run();
        if (result.meta.changes !== 1) {
            throw new OAuthCredentialError("TRANSIENT_GITHUB_FAILURE");
        }
        return {
            accessToken: encryptedAccessToken,
            refreshToken: encryptedRefreshToken,
        };
    }

    private async setHealthState(
        credentialID: string,
        state: CredentialRecord["health_state"]
    ): Promise<void> {
        await this.database.prepare(
            "UPDATE oauth_credentials SET health_state = ?, updated_at = ? WHERE id = ?"
        ).bind(state, new Date(this.now()).toISOString(), credentialID).run();
    }

    private async saveValidatedScopes(credentialID: string, scopes: string[]): Promise<void> {
        await this.database.prepare(
            `UPDATE oauth_credentials
             SET granted_scopes = ?, health_state = 'ACTIVE', updated_at = ?
             WHERE id = ?`
        ).bind(
            JSON.stringify(scopes),
            new Date(this.now()).toISOString(),
            credentialID
        ).run();
    }

    private expiresWithinBuffer(value: string): boolean {
        return Date.parse(value) - this.now() <= expiryBufferMilliseconds;
    }

    private isExpired(value: string): boolean {
        return Date.parse(value) <= this.now();
    }
}

export async function encryptCredentialToken(
    credentialID: string,
    purpose: "access" | "refresh",
    token: string,
    encodedKey: string
): Promise<string> {
    const key = await importEncryptionKey(encodedKey, ["encrypt"]);
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const encrypted = await crypto.subtle.encrypt(
        {
            name: "AES-GCM",
            iv: nonce,
            additionalData: associatedData(credentialID, purpose),
        },
        key,
        new TextEncoder().encode(token)
    );
    return `v1.${base64URL(nonce)}.${base64URL(new Uint8Array(encrypted))}`;
}

export async function decryptCredentialToken(
    credentialID: string,
    purpose: "access" | "refresh",
    envelope: string,
    encodedKey: string
): Promise<string> {
    const [version, encodedNonce, encodedCiphertext, extra] = envelope.split(".");
    if (version !== "v1" || !encodedNonce || !encodedCiphertext || extra) {
        throw new OAuthCredentialError("OAUTH_REAUTH_REQUIRED");
    }
    try {
        const key = await importEncryptionKey(encodedKey, ["decrypt"]);
        const decrypted = await crypto.subtle.decrypt(
            {
                name: "AES-GCM",
                iv: decodeBase64URL(encodedNonce),
                additionalData: associatedData(credentialID, purpose),
            },
            key,
            decodeBase64URL(encodedCiphertext)
        );
        return new TextDecoder().decode(decrypted);
    } catch {
        throw new OAuthCredentialError("OAUTH_REAUTH_REQUIRED");
    }
}

function associatedData(credentialID: string, purpose: string): Uint8Array<ArrayBuffer> {
    return new TextEncoder().encode(`v1:${credentialID}:${purpose}`);
}

async function importEncryptionKey(
    value: string,
    usages: KeyUsage[]
): Promise<CryptoKey> {
    const bytes = decodeBase64URL(value);
    if (bytes.byteLength !== 32) {
        throw new OAuthCredentialError("OAUTH_REAUTH_REQUIRED");
    }
    return crypto.subtle.importKey("raw", bytes, "AES-GCM", false, usages);
}

function decodeScopes(value: string): string[] {
    try {
        const scopes: unknown = JSON.parse(value);
        return Array.isArray(scopes)
            ? scopes.filter((scope): scope is string => typeof scope === "string")
            : [];
    } catch {
        return [];
    }
}

function parseScopeHeader(value: string | null): string[] {
    return (value ?? "")
        .split(",")
        .map((scope) => scope.trim())
        .filter(Boolean);
}

function isUnauthorized(error: unknown): boolean {
    return isRecord(error) && error.status === 401;
}

function base64URL(value: Uint8Array): string {
    return btoa(String.fromCharCode(...value))
        .replace(/=/g, "")
        .replace(/\+/g, "-")
        .replace(/\//g, "_");
}

function decodeBase64URL(value: string): Uint8Array<ArrayBuffer> {
    const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
    const padding = "=".repeat((4 - base64.length % 4) % 4);
    return Uint8Array.from(atob(base64 + padding), (character) => character.charCodeAt(0));
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
}

function isPositiveNumber(value: unknown): value is number {
    return typeof value === "number" && Number.isFinite(value) && value > 0;
}
