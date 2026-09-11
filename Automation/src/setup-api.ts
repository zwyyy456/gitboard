import { GitHubAppClient, GitHubAppRequestError, type GitHubInstallation } from "./github-app-client";
import { replaceRepositories } from "./installation-lifecycle";
import { encryptCredentialToken, OAuthCredentialError } from "./oauth-credential-provider";
import { SetupProjectError } from "./setup-project-client";
import type { Env } from "./index";
import {
    SetupRequestError, authenticateSetupSession, createSetupSession, loadSession,
    publicBaseURL, publicSession, requireState, randomToken, hashToken, positiveInteger, type SetupSessionRecord,
} from "./setup-session";
import { exchangeOAuthCode, loadGitHubUser, type GitHubOAuthToken, type GitHubUser } from "./setup-oauth";
import { completeSetup, recoverSetup, listSetupOptions, listProjectFields } from "./setup-completion";

const githubOAuthEndpoint = "https://github.com/login/oauth";

const setupCookieName = "gb_setup";

export async function handleSetupRequest(request: Request, env: Env): Promise<Response> {
    try {
        const url = new URL(request.url);
        if (request.method === "POST" && url.pathname === "/api/setup/sessions") {
            return await createSetupSession(request, env);
        }
        if (request.method === "GET" && /^\/setup\/[^/]+\/oauth$/.test(url.pathname)) {
            return await beginOAuth(url.pathname.split("/")[2], env);
        }
        if (request.method === "GET" && url.pathname === "/oauth/callback") {
            return await finishOAuth(url, env);
        }
        if (request.method === "GET" && url.pathname === "/setup/github-app") {
            return await finishInstallation(request, url, env);
        }
        const setupMatch = url.pathname.match(/^\/api\/setup\/sessions\/([^/]+)(?:\/(options|project-fields|complete|recover))?$/);
        if (setupMatch) {
            let session = await authenticateSetupSession(request, setupMatch[1], env.DB);
            session = await recognizeExistingAutomation(session, env.DB);
            if (request.method === "GET" && !setupMatch[2]) {
                return Response.json(publicSession(session));
            }
            if (request.method === "GET" && setupMatch[2] === "options") {
                if (session.state === "RECOVERY_PENDING") {
                    throw new SetupRequestError(409, "ACCOUNT_AUTOMATION_ALREADY_CONFIGURED");
                }
                return await listSetupOptions(session, env);
            }
            if (request.method === "POST" && setupMatch[2] === "project-fields") {
                return await listProjectFields(request, session, env);
            }
            if (request.method === "POST" && setupMatch[2] === "recover") {
                return await recoverSetup(request, session, env);
            }
            if (request.method === "POST" && setupMatch[2] === "complete") {
                if (session.state === "RECOVERY_PENDING") {
                    throw new SetupRequestError(409, "ACCOUNT_AUTOMATION_ALREADY_CONFIGURED");
                }
                return await completeSetup(request, session, env);
            }
        }
        return new Response("Not found", { status: 404 });
    } catch (error) {
        const setupError = classifySetupError(error);
        return Response.json({ error: setupError.code }, { status: setupError.status });
    }
}

async function beginOAuth(sessionID: string, env: Env): Promise<Response> {
    const session = await loadSession(env.DB, sessionID);
    requireState(session, "OAUTH_PENDING");
    const state = randomToken();
    await env.DB.prepare(
        "UPDATE setup_sessions SET oauth_state_hash = ?, updated_at = ? WHERE id = ?"
    ).bind(await hashToken(state), new Date().toISOString(), session.id).run();
    const authorizationURL = new URL(`${githubOAuthEndpoint}/authorize`);
    authorizationURL.searchParams.set("client_id", env.GITHUB_OAUTH_CLIENT_ID);
    authorizationURL.searchParams.set("redirect_uri", `${publicBaseURL(env)}/oauth/callback`);
    authorizationURL.searchParams.set("scope", "project offline_access");
    authorizationURL.searchParams.set("state", state);
    return Response.redirect(authorizationURL.toString(), 302);
}

async function finishOAuth(url: URL, env: Env): Promise<Response> {
    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state");
    if (!code || !state) throw new SetupRequestError(400, "INVALID_OAUTH_CALLBACK");

    const session = await env.DB.prepare(
        `SELECT id, setup_token_hash, user_id, oauth_credential_id, installation_id,
                state, expires_at, purpose, automation_id, management_token_id
         FROM setup_sessions
         WHERE oauth_state_hash = ?`
    ).bind(await hashToken(state)).first<SetupSessionRecord>();
    if (!session) throw new SetupRequestError(400, "INVALID_OAUTH_STATE");
    requireState(session, "OAUTH_PENDING");

    const token = await exchangeOAuthCode(code, env);
    const user = await loadGitHubUser(token.accessToken, env.GITHUB_API_VERSION);
    if (!user.scopes.includes("project")) {
        throw new SetupRequestError(403, "OAUTH_SCOPE_MISSING");
    }
    if (session.purpose === "REAUTHORIZE") {
        return finishReauthorizationOAuth(session, token, user, env);
    }
    const existingUser = await env.DB.prepare(
        "SELECT id FROM users WHERE github_user_database_id = ?"
    ).bind(user.databaseID).first<{ id: string }>();
    const userID = existingUser?.id ?? crypto.randomUUID();
    const credentialID = crypto.randomUUID();
    const now = new Date().toISOString();
    const encryptedAccessToken = await encryptCredentialToken(
        credentialID, "access", token.accessToken, env.OAUTH_TOKEN_ENCRYPTION_KEY
    );
    const encryptedRefreshToken = await encryptCredentialToken(
        credentialID, "refresh", token.refreshToken, env.OAUTH_TOKEN_ENCRYPTION_KEY
    );
    const results = await env.DB.batch([
        env.DB.prepare(
            `INSERT INTO users (
                id, github_user_node_id, github_user_database_id, github_login, created_at, updated_at
             ) VALUES (?, ?, ?, ?, ?, ?)
             ON CONFLICT(github_user_database_id) DO UPDATE SET
                github_user_node_id = excluded.github_user_node_id,
                github_login = excluded.github_login,
                updated_at = excluded.updated_at`
        ).bind(userID, user.nodeID, user.databaseID, user.login, now, now),
        env.DB.prepare(
            `INSERT INTO oauth_credentials (
                id, user_id, encrypted_access_token, encrypted_refresh_token,
                access_token_expires_at, refresh_token_expires_at, granted_scopes,
                credential_version, health_state, updated_at
             ) VALUES (?, ?, ?, ?, ?, ?, ?, 1, 'ACTIVE', ?)`
        ).bind(
            credentialID, userID, encryptedAccessToken, encryptedRefreshToken,
            token.accessTokenExpiresAt, token.refreshTokenExpiresAt,
            JSON.stringify(user.scopes), now
        ),
        env.DB.prepare(
            `UPDATE setup_sessions
             SET user_id = ?, oauth_credential_id = ?, oauth_state_hash = NULL,
                 state = 'INSTALLATION_PENDING', updated_at = ?
             WHERE id = ? AND state = 'OAUTH_PENDING'`
        ).bind(userID, credentialID, now, session.id),
    ]);
    if (results[2].meta.changes !== 1) {
        throw new SetupRequestError(409, "SETUP_STATE_CHANGED");
    }

    const app = appClient(env);
    const existingInstallation = await app.getUserInstallation(user.login);
    if (existingInstallation) {
        const callbackURL = new URL(`${publicBaseURL(env)}/setup/github-app`);
        callbackURL.searchParams.set("installation_id", String(existingInstallation.id));
        return new Response(null, {
            status: 302,
            headers: {
                Location: callbackURL.toString(),
                "Set-Cookie": setupCookie(session.id, env),
            },
        });
    }

    return new Response(null, {
        status: 302,
        headers: {
            Location: `https://github.com/apps/${encodeURIComponent(env.GITHUB_APP_SLUG)}/installations/new`,
            "Set-Cookie": setupCookie(session.id, env),
        },
    });
}

async function finishReauthorizationOAuth(
    session: SetupSessionRecord,
    token: GitHubOAuthToken,
    user: GitHubUser,
    env: Env
): Promise<Response> {
    if (!session.user_id || !session.oauth_credential_id || !session.automation_id) {
        throw new SetupRequestError(409, "SETUP_STATE_CHANGED");
    }
    const expectedUser = await env.DB.prepare(
        "SELECT github_user_database_id FROM users WHERE id = ?"
    ).bind(session.user_id).first<{ github_user_database_id: number }>();
    if (!expectedUser || expectedUser.github_user_database_id !== user.databaseID) {
        throw new SetupRequestError(403, "OAUTH_ACCOUNT_MISMATCH");
    }

    const encryptedAccessToken = await encryptCredentialToken(
        session.oauth_credential_id,
        "access",
        token.accessToken,
        env.OAUTH_TOKEN_ENCRYPTION_KEY
    );
    const encryptedRefreshToken = await encryptCredentialToken(
        session.oauth_credential_id,
        "refresh",
        token.refreshToken,
        env.OAUTH_TOKEN_ENCRYPTION_KEY
    );
    const now = new Date().toISOString();
    const results = await env.DB.batch([
        env.DB.prepare(
            `UPDATE users
             SET github_user_node_id = ?, github_login = ?, updated_at = ?
             WHERE id = ?`
        ).bind(user.nodeID, user.login, now, session.user_id),
        env.DB.prepare(
            `UPDATE oauth_credentials
             SET encrypted_access_token = ?, encrypted_refresh_token = ?,
                 access_token_expires_at = ?, refresh_token_expires_at = ?,
                 granted_scopes = ?, credential_version = credential_version + 1,
                 health_state = 'ACTIVE', updated_at = ?
             WHERE id = ? AND user_id = ?`
        ).bind(
            encryptedAccessToken, encryptedRefreshToken,
            token.accessTokenExpiresAt, token.refreshTokenExpiresAt,
            JSON.stringify(user.scopes), now,
            session.oauth_credential_id, session.user_id
        ),
        env.DB.prepare(
            `UPDATE project_automations
             SET enabled = 1, health_state = 'CONTENT_VISIBILITY_UNVERIFIED', updated_at = ?
             WHERE id = ? AND user_id = ?`
        ).bind(now, session.automation_id, session.user_id),
        env.DB.prepare(
            `UPDATE setup_sessions
             SET oauth_state_hash = NULL, state = 'COMPLETE', updated_at = ?
             WHERE id = ? AND state = 'OAUTH_PENDING'`
        ).bind(now, session.id),
    ]);
    if (results[1].meta.changes !== 1
        || results[2].meta.changes !== 1
        || results[3].meta.changes !== 1) {
        throw new SetupRequestError(409, "SETUP_STATE_CHANGED");
    }
    return new Response(reauthorizationCompleteHTML, {
        headers: { "Content-Type": "text/html; charset=utf-8" },
    });
}

async function finishInstallation(request: Request, url: URL, env: Env): Promise<Response> {
    const installationID = positiveInteger(url.searchParams.get("installation_id"));
    const sessionID = readCookie(request.headers.get("Cookie"), setupCookieName);
    if (!installationID || !sessionID) {
        throw new SetupRequestError(400, "INVALID_INSTALLATION_CALLBACK");
    }
    const session = await loadSession(env.DB, sessionID);
    requireState(session, "INSTALLATION_PENDING");

    const app = appClient(env);
    const installation = await app.getInstallation(installationID);
    await connectInstallation(session, installation, app, env);

    return new Response(setupCompleteHTML, {
        headers: {
            "Content-Type": "text/html; charset=utf-8",
            "Set-Cookie": `${setupCookieName}=; HttpOnly;${secureCookieAttribute(env)} SameSite=Lax; Path=/setup/github-app; Max-Age=0`,
        },
    });
}

async function connectInstallation(
    session: SetupSessionRecord,
    installation: GitHubInstallation,
    app: GitHubAppClient,
    env: Env
): Promise<void> {
    requireState(session, "INSTALLATION_PENDING");
    if (!session.user_id) throw new SetupRequestError(409, "SETUP_STATE_CHANGED");

    const user = await env.DB.prepare(
        "SELECT github_user_database_id FROM users WHERE id = ?"
    ).bind(session.user_id).first<{ github_user_database_id: number }>();
    if (!user
        || installation.accountType !== "User"
        || installation.accountID !== user.github_user_database_id) {
        throw new SetupRequestError(403, "INSTALLATION_ACCOUNT_MISMATCH");
    }
    if (installation.status !== "ACTIVE") {
        throw new SetupRequestError(409, "INSTALLATION_NOT_ACTIVE");
    }
    const repositories = await app.listInstallationRepositories(installation.id);
    const now = new Date().toISOString();
    await env.DB.prepare(
        `INSERT INTO installations (installation_id, user_id, github_account_id, status, updated_at)
         VALUES (?, ?, ?, 'ACTIVE', ?)
         ON CONFLICT(installation_id) DO UPDATE SET
            user_id = excluded.user_id,
            github_account_id = excluded.github_account_id,
            status = 'ACTIVE',
            updated_at = excluded.updated_at`
    ).bind(installation.id, session.user_id, installation.accountID, now).run();
    await replaceRepositories(env.DB, installation.id, repositories);
    const result = await env.DB.prepare(
        `UPDATE setup_sessions
         SET installation_id = ?, state = 'CONFIGURATION_PENDING', updated_at = ?
         WHERE id = ? AND state = 'INSTALLATION_PENDING'`
    ).bind(installation.id, now, session.id).run();
    if (result.meta.changes !== 1) throw new SetupRequestError(409, "SETUP_STATE_CHANGED");
}

async function recognizeExistingAutomation(
    session: SetupSessionRecord,
    database: D1Database
): Promise<SetupSessionRecord> {
    if (session.state !== "CONFIGURATION_PENDING" || session.purpose !== "INITIAL") return session;
    const existing = await database.prepare(
        "SELECT id FROM project_automations WHERE installation_id = ? AND user_id = ?"
    ).bind(session.installation_id, session.user_id).first<{ id: string }>();
    if (!existing) return session;
    await database.prepare(
        `UPDATE setup_sessions SET state = 'RECOVERY_PENDING', automation_id = ?
         WHERE id = ? AND state = 'CONFIGURATION_PENDING'`
    ).bind(existing.id, session.id).run();
    return loadSession(database, session.id);
}

function appClient(env: Env): GitHubAppClient {
    return new GitHubAppClient(
        env.GITHUB_APP_ID,
        env.GITHUB_APP_PRIVATE_KEY,
        env.GITHUB_API_VERSION
    );
}

function setupCookie(sessionID: string, env: Env): string {
    return `${setupCookieName}=${sessionID}; HttpOnly;${secureCookieAttribute(env)} SameSite=Lax; Path=/setup/github-app; Max-Age=1800`;
}

function secureCookieAttribute(env: Env): string {
    return new URL(env.PUBLIC_BASE_URL).protocol === "https:" ? " Secure;" : "";
}

function readCookie(header: string | null, name: string): string | null {
    for (const part of (header ?? "").split(";")) {
        const [key, ...value] = part.trim().split("=");
        if (key === name) return value.join("=") || null;
    }
    return null;
}

function classifySetupError(error: unknown): SetupRequestError {
    if (error instanceof SetupRequestError) return error;
    if (error instanceof OAuthCredentialError) {
        return new SetupRequestError(
            error.code === "TRANSIENT_GITHUB_FAILURE" ? 503 : 401,
            error.code
        );
    }
    if (error instanceof SetupProjectError) {
        return new SetupRequestError(
            error.code === "TRANSIENT_GITHUB_FAILURE" ? 503 : 400,
            error.code
        );
    }
    if (error instanceof GitHubAppRequestError) {
        return new SetupRequestError(error.retryable ? 503 : 400, "INSTALLATION_LOOKUP_FAILED");
    }
    return new SetupRequestError(500, "SETUP_UNAVAILABLE");
}

const setupCompleteHTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>GitStride setup</title></head><body><main><h1>Authorization complete</h1>
<p>Return to GitStride to finish connecting automation.</p></main></body></html>`;

const reauthorizationCompleteHTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>GitStride authorization</title></head><body><main><h1>GitStride is reauthorized</h1>
<p>You can return to GitStride.</p></main></body></html>`;
