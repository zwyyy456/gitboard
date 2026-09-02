import { GitHubAppClient, GitHubAppRequestError } from "./github-app-client";
import { GitHubGraphQLClient } from "./github-graphql";
import { replaceRepositories } from "./installation-lifecycle";
import {
    encryptCredentialToken,
    OAuthCredentialError,
    OAuthCredentialProvider,
} from "./oauth-credential-provider";
import { SetupProjectClient, SetupProjectError } from "./setup-project-client";
import type { Env } from "./index";

const setupLifetimeMilliseconds = 30 * 60 * 1000;
const githubOAuthEndpoint = "https://github.com/login/oauth";
const githubAPI = "https://api.github.com";
const setupCookieName = "gb_setup";

type SetupState = "OAUTH_PENDING" | "INSTALLATION_PENDING" | "CONFIGURATION_PENDING" | "COMPLETE" | "EXCHANGED";

interface SetupSessionRecord {
    id: string;
    setup_token_hash: string;
    user_id: string | null;
    oauth_credential_id: string | null;
    installation_id: number | null;
    state: SetupState;
    expires_at: string;
    purpose?: "INITIAL" | "REAUTHORIZE";
    automation_id?: string | null;
    github_user_database_id?: number;
    github_login?: string;
}

interface GitHubOAuthToken {
    accessToken: string;
    refreshToken: string;
    accessTokenExpiresAt: string;
    refreshTokenExpiresAt: string;
}

interface GitHubUser {
    databaseID: number;
    nodeID: string;
    login: string;
    scopes: string[];
}

interface SetupSelection {
    sourceRepositoryID: number;
    projectNodeID: string;
    projectNumber: number;
    statusFieldNodeID: string;
    inProgressOptionID: string;
    inReviewOptionID: string;
    doneOptionID: string;
}

export async function handleSetupRequest(request: Request, env: Env): Promise<Response> {
    try {
        const url = new URL(request.url);
        if (request.method === "POST" && url.pathname === "/api/setup/sessions") {
            return createSetupSession(env);
        }
        if (request.method === "GET" && /^\/setup\/[^/]+\/oauth$/.test(url.pathname)) {
            return beginOAuth(url.pathname.split("/")[2], env);
        }
        if (request.method === "GET" && url.pathname === "/oauth/callback") {
            return finishOAuth(url, env);
        }
        if (request.method === "GET" && url.pathname === "/setup/github-app") {
            return finishInstallation(request, url, env);
        }
        const setupMatch = url.pathname.match(/^\/api\/setup\/sessions\/([^/]+)(?:\/(options|project-fields|complete))?$/);
        if (setupMatch) {
            const session = await authenticateSetupSession(request, setupMatch[1], env.DB);
            if (request.method === "GET" && !setupMatch[2]) {
                return Response.json(publicSession(session));
            }
            if (request.method === "GET" && setupMatch[2] === "options") {
                return listSetupOptions(session, env);
            }
            if (request.method === "POST" && setupMatch[2] === "project-fields") {
                return listProjectFields(request, session, env);
            }
            if (request.method === "POST" && setupMatch[2] === "complete") {
                return completeSetup(request, session, env);
            }
        }
        if (request.method === "POST" && url.pathname === "/api/management/token") {
            return exchangeManagementToken(request, env.DB);
        }
        return new Response("Not found", { status: 404 });
    } catch (error) {
        const setupError = classifySetupError(error);
        return Response.json({ error: setupError.code }, { status: setupError.status });
    }
}

async function createSetupSession(env: Env): Promise<Response> {
    const id = crypto.randomUUID();
    const setupToken = randomToken();
    const now = new Date();
    const expiresAt = new Date(now.getTime() + setupLifetimeMilliseconds).toISOString();
    await env.DB.prepare(
        `INSERT INTO setup_sessions (
            id, setup_token_hash, state, expires_at, created_at, updated_at
         ) VALUES (?, ?, 'OAUTH_PENDING', ?, ?, ?)`
    ).bind(id, await hashToken(setupToken), expiresAt, now.toISOString(), now.toISOString()).run();
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
                state, expires_at, purpose, automation_id
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

    const response = Response.redirect(
        `https://github.com/apps/${encodeURIComponent(env.GITHUB_APP_SLUG)}/installations/new`,
        302
    );
    response.headers.append("Set-Cookie", setupCookie(session.id, env));
    return response;
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
    if (!session.user_id) throw new SetupRequestError(409, "SETUP_STATE_CHANGED");

    const app = appClient(env);
    const installation = await app.getInstallation(installationID);
    const user = await env.DB.prepare(
        "SELECT github_user_database_id FROM users WHERE id = ?"
    ).bind(session.user_id).first<{ github_user_database_id: number }>();
    if (!user
        || installation.accountType !== "User"
        || installation.accountID !== user.github_user_database_id) {
        throw new SetupRequestError(403, "INSTALLATION_ACCOUNT_MISMATCH");
    }
    const repositories = await app.listInstallationRepositories(installationID);
    const now = new Date().toISOString();
    await env.DB.prepare(
        `INSERT INTO installations (installation_id, user_id, github_account_id, status, updated_at)
         VALUES (?, ?, ?, 'ACTIVE', ?)
         ON CONFLICT(installation_id) DO UPDATE SET
            user_id = excluded.user_id,
            github_account_id = excluded.github_account_id,
            status = 'ACTIVE',
            updated_at = excluded.updated_at`
    ).bind(installationID, session.user_id, installation.accountID, now).run();
    await replaceRepositories(env.DB, installationID, repositories);
    const result = await env.DB.prepare(
        `UPDATE setup_sessions
         SET installation_id = ?, state = 'CONFIGURATION_PENDING', updated_at = ?
         WHERE id = ? AND state = 'INSTALLATION_PENDING'`
    ).bind(installationID, now, session.id).run();
    if (result.meta.changes !== 1) throw new SetupRequestError(409, "SETUP_STATE_CHANGED");

    return new Response(setupCompleteHTML, {
        headers: {
            "Content-Type": "text/html; charset=utf-8",
            "Set-Cookie": `${setupCookieName}=; HttpOnly;${secureCookieAttribute(env)} SameSite=Lax; Path=/setup/github-app; Max-Age=0`,
        },
    });
}

async function listSetupOptions(session: SetupSessionRecord, env: Env): Promise<Response> {
    requireState(session, "CONFIGURATION_PENDING");
    const context = requireConfigurationContext(session);
    const repositories = await env.DB.prepare(
        `SELECT repository_id, name_with_owner
         FROM installation_repositories
         WHERE installation_id = ?
         ORDER BY name_with_owner COLLATE NOCASE`
    ).bind(context.installationID).all<{ repository_id: number; name_with_owner: string }>();
    const projects = await withSetupAccessToken(session, env, (token, ownerLogin, client) => (
        client.listProjects(token, ownerLogin)
    ));
    return Response.json({
        state: session.state,
        repositories: repositories.results.map((repository) => ({
            id: repository.repository_id,
            nameWithOwner: repository.name_with_owner,
        })),
        projects,
    });
}

async function listProjectFields(
    request: Request,
    session: SetupSessionRecord,
    env: Env
): Promise<Response> {
    requireState(session, "CONFIGURATION_PENDING");
    const body = await readJSONObject(request);
    const projectNodeID = nonEmptyString(body.projectNodeID);
    const projectNumber = positiveInteger(body.projectNumber);
    if (!projectNodeID || !projectNumber) throw new SetupRequestError(400, "INVALID_SELECTION");

    const fields = await withSetupAccessToken(session, env, async (token, ownerLogin, client) => {
        await requireSelectedProject(client, token, ownerLogin, projectNodeID, projectNumber);
        return client.listStatusFields(token, ownerLogin, projectNumber);
    });
    return Response.json({ fields });
}

async function completeSetup(
    request: Request,
    session: SetupSessionRecord,
    env: Env
): Promise<Response> {
    requireState(session, "CONFIGURATION_PENDING");
    const selection = parseSelection(await readJSONObject(request));
    const context = requireConfigurationContext(session);
    const repository = await env.DB.prepare(
        `SELECT name_with_owner FROM installation_repositories
         WHERE installation_id = ? AND repository_id = ?`
    ).bind(context.installationID, selection.sourceRepositoryID)
        .first<{ name_with_owner: string }>();
    if (!repository) throw new SetupRequestError(400, "INVALID_SOURCE_REPOSITORY");
    const existingAutomation = await env.DB.prepare(
        `SELECT id FROM project_automations
         WHERE installation_id = ? AND repository_id = ?`
    ).bind(context.installationID, selection.sourceRepositoryID).first<{ id: string }>();
    if (existingAutomation) {
        throw new SetupRequestError(409, "SOURCE_REPOSITORY_ALREADY_CONFIGURED");
    }

    const installationToken = await appClient(env).createInstallationAccessToken(
        context.installationID
    );
    const configuration = await withSetupAccessToken(session, env, async (token, login, client) => {
        await requireSelectedProject(
            client, token, login, selection.projectNodeID, selection.projectNumber
        );
        const fields = await client.listStatusFields(token, login, selection.projectNumber);
        const field = fields.find((candidate) => candidate.nodeID === selection.statusFieldNodeID);
        const optionIDs = new Set(field?.options.map((option) => option.id));
        if (!field
            || !optionIDs.has(selection.inProgressOptionID)
            || !optionIDs.has(selection.inReviewOptionID)
            || !optionIDs.has(selection.doneOptionID)) {
            throw new SetupRequestError(400, "INVALID_STATUS_MAPPING");
        }
        await client.requireProjectWriteAccess(token, selection.projectNodeID);
        const visibility = await client.probeContentVisibility(
            token,
            installationToken,
            login,
            selection.projectNumber,
            repository.name_with_owner
        );
        return { ownerLogin: login, visibility };
    });

    const automationID = crypto.randomUUID();
    const completionCode = randomToken();
    const now = new Date().toISOString();
    const results = await env.DB.batch([
        env.DB.prepare(
            `INSERT INTO project_automations (
                id, user_id, oauth_credential_id, installation_id,
                repository_id, repository_name_with_owner,
                project_owner_login, project_number, project_node_id,
                status_field_node_id, in_progress_option_id, in_review_option_id,
                done_option_id, enabled, health_state, created_at, updated_at
             ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)`
        ).bind(
            automationID, context.userID, context.credentialID, context.installationID,
            selection.sourceRepositoryID, repository.name_with_owner,
            configuration.ownerLogin, selection.projectNumber, selection.projectNodeID,
            selection.statusFieldNodeID, selection.inProgressOptionID,
            selection.inReviewOptionID, selection.doneOptionID,
            configuration.visibility === "VERIFIED"
                ? "ACTIVE"
                : "CONTENT_VISIBILITY_UNVERIFIED",
            now, now
        ),
        env.DB.prepare(
            `UPDATE setup_sessions
             SET exchange_code_hash = ?, state = 'COMPLETE', updated_at = ?
             WHERE id = ? AND state = 'CONFIGURATION_PENDING'`
        ).bind(await hashToken(completionCode), now, session.id),
    ]);
    if (results[1].meta.changes !== 1) {
        throw new SetupRequestError(409, "SETUP_STATE_CHANGED");
    }
    return Response.json({ completionCode, automationID });
}

async function exchangeManagementToken(request: Request, database: D1Database): Promise<Response> {
    const body = await readJSONObject(request);
    const sessionID = nonEmptyString(body.sessionID);
    const completionCode = nonEmptyString(body.completionCode);
    if (!sessionID || !completionCode) throw new SetupRequestError(400, "INVALID_COMPLETION_CODE");
    const session = await database.prepare(
        `SELECT id, setup_token_hash, user_id, oauth_credential_id, installation_id, state, expires_at
         FROM setup_sessions
         WHERE id = ? AND exchange_code_hash = ?`
    ).bind(sessionID, await hashToken(completionCode)).first<SetupSessionRecord>();
    if (!session) throw new SetupRequestError(401, "INVALID_COMPLETION_CODE");
    requireState(session, "COMPLETE");
    if (!session.user_id) throw new SetupRequestError(409, "SETUP_STATE_CHANGED");

    const managementToken = randomToken();
    const now = new Date().toISOString();
    const results = await database.batch([
        database.prepare(
            `INSERT INTO management_tokens (id, user_id, token_hash, created_at)
             SELECT ?, user_id, ?, ?
             FROM setup_sessions
             WHERE id = ? AND state = 'COMPLETE'`
        ).bind(
            crypto.randomUUID(), await hashToken(managementToken), now, session.id
        ),
        database.prepare(
            `UPDATE setup_sessions
             SET exchange_code_hash = NULL, state = 'EXCHANGED', updated_at = ?
             WHERE id = ? AND state = 'COMPLETE'`
        ).bind(now, session.id),
    ]);
    if (results[0].meta.changes !== 1 || results[1].meta.changes !== 1) {
        throw new SetupRequestError(409, "SETUP_STATE_CHANGED");
    }
    return Response.json({ managementToken });
}

async function authenticateSetupSession(
    request: Request,
    sessionID: string,
    database: D1Database
): Promise<SetupSessionRecord> {
    const token = bearerToken(request.headers.get("Authorization"));
    if (!token) throw new SetupRequestError(401, "SETUP_AUTH_REQUIRED");
    const session = await database.prepare(
        `SELECT session.id, session.setup_token_hash, session.user_id,
                session.oauth_credential_id, session.installation_id,
                session.state, session.expires_at, user.github_login
         FROM setup_sessions session
         LEFT JOIN users user ON user.id = session.user_id
         WHERE session.id = ? AND session.setup_token_hash = ?`
    ).bind(sessionID, await hashToken(token)).first<SetupSessionRecord>();
    if (!session) throw new SetupRequestError(401, "SETUP_AUTH_REQUIRED");
    requireNotExpired(session);
    return session;
}

async function loadSession(database: D1Database, sessionID: string): Promise<SetupSessionRecord> {
    const session = await database.prepare(
        `SELECT id, setup_token_hash, user_id, oauth_credential_id, installation_id, state, expires_at
         FROM setup_sessions WHERE id = ?`
    ).bind(sessionID).first<SetupSessionRecord>();
    if (!session) throw new SetupRequestError(404, "SETUP_NOT_FOUND");
    requireNotExpired(session);
    return session;
}

async function withSetupAccessToken<T>(
    session: SetupSessionRecord,
    env: Env,
    operation: (
        token: string,
        ownerLogin: string,
        client: SetupProjectClient
    ) => Promise<T>
): Promise<T> {
    if (!session.oauth_credential_id || !session.github_login) {
        throw new SetupRequestError(409, "SETUP_STATE_CHANGED");
    }
    const provider = new OAuthCredentialProvider(env.DB, {
        clientID: env.GITHUB_OAUTH_CLIENT_ID,
        clientSecret: env.GITHUB_OAUTH_CLIENT_SECRET,
        encryptionKey: env.OAUTH_TOKEN_ENCRYPTION_KEY,
        apiVersion: env.GITHUB_API_VERSION,
    });
    const client = new SetupProjectClient(
        new GitHubGraphQLClient(env.GITHUB_API_VERSION),
        env.GITHUB_API_VERSION
    );
    return provider.withValidAccessToken(session.oauth_credential_id, (token) => (
        operation(token, session.github_login!, client)
    ));
}

async function requireSelectedProject(
    client: SetupProjectClient,
    accessToken: string,
    ownerLogin: string,
    projectNodeID: string,
    projectNumber: number
): Promise<void> {
    const projects = await client.listProjects(accessToken, ownerLogin);
    if (!projects.some((project) => (
        project.nodeID === projectNodeID && project.number === projectNumber
    ))) {
        throw new SetupRequestError(400, "INVALID_PROJECT");
    }
}

async function exchangeOAuthCode(code: string, env: Env): Promise<GitHubOAuthToken> {
    let response: Response;
    try {
        response = await fetch(`${githubOAuthEndpoint}/access_token`, {
            method: "POST",
            headers: {
                Accept: "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
            },
            body: new URLSearchParams({
                client_id: env.GITHUB_OAUTH_CLIENT_ID,
                client_secret: env.GITHUB_OAUTH_CLIENT_SECRET,
                code,
                redirect_uri: `${publicBaseURL(env)}/oauth/callback`,
            }),
        });
    } catch {
        throw new SetupRequestError(503, "GITHUB_UNAVAILABLE");
    }
    if (!response.ok) throw new SetupRequestError(401, "OAUTH_EXCHANGE_FAILED");
    let body: unknown;
    try {
        body = await response.json();
    } catch {
        throw new SetupRequestError(502, "INVALID_OAUTH_RESPONSE");
    }
    if (!isRecord(body)
        || typeof body.access_token !== "string"
        || typeof body.refresh_token !== "string"
        || !isPositiveNumber(body.expires_in)
        || !isPositiveNumber(body.refresh_token_expires_in)) {
        throw new SetupRequestError(401, "OAUTH_EXCHANGE_FAILED");
    }
    const now = Date.now();
    return {
        accessToken: body.access_token,
        refreshToken: body.refresh_token,
        accessTokenExpiresAt: new Date(now + body.expires_in * 1000).toISOString(),
        refreshTokenExpiresAt: new Date(now + body.refresh_token_expires_in * 1000).toISOString(),
    };
}

async function loadGitHubUser(accessToken: string, apiVersion: string): Promise<GitHubUser> {
    let response: Response;
    try {
        response = await fetch(`${githubAPI}/user`, {
            headers: {
                Accept: "application/vnd.github+json",
                Authorization: `Bearer ${accessToken}`,
                "User-Agent": "GitBoard-Automation",
                "X-GitHub-Api-Version": apiVersion,
            },
        });
    } catch {
        throw new SetupRequestError(503, "GITHUB_UNAVAILABLE");
    }
    if (!response.ok) throw new SetupRequestError(401, "OAUTH_IDENTITY_FAILED");
    let body: unknown;
    try {
        body = await response.json();
    } catch {
        throw new SetupRequestError(502, "INVALID_OAUTH_RESPONSE");
    }
    if (!isRecord(body)
        || !isPositiveInteger(body.id)
        || typeof body.node_id !== "string"
        || typeof body.login !== "string"
        || body.type !== "User") {
        throw new SetupRequestError(502, "INVALID_OAUTH_RESPONSE");
    }
    return {
        databaseID: body.id,
        nodeID: body.node_id,
        login: body.login,
        scopes: (response.headers.get("X-OAuth-Scopes") ?? "")
            .split(",").map((scope) => scope.trim()).filter(Boolean),
    };
}

function requireConfigurationContext(session: SetupSessionRecord): {
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

function requireState(session: SetupSessionRecord, state: SetupState): void {
    requireNotExpired(session);
    if (session.state !== state) throw new SetupRequestError(409, "SETUP_STATE_CHANGED");
}

function requireNotExpired(session: SetupSessionRecord): void {
    if (Date.parse(session.expires_at) <= Date.now()) {
        throw new SetupRequestError(410, "SETUP_EXPIRED");
    }
}

function parseSelection(body: Record<string, unknown>): SetupSelection {
    const selection = {
        sourceRepositoryID: positiveInteger(body.sourceRepositoryID),
        projectNodeID: nonEmptyString(body.projectNodeID),
        projectNumber: positiveInteger(body.projectNumber),
        statusFieldNodeID: nonEmptyString(body.statusFieldNodeID),
        inProgressOptionID: nonEmptyString(body.inProgressOptionID),
        inReviewOptionID: nonEmptyString(body.inReviewOptionID),
        doneOptionID: nonEmptyString(body.doneOptionID),
    };
    if (Object.values(selection).some((value) => value === null)) {
        throw new SetupRequestError(400, "INVALID_SELECTION");
    }
    return selection as SetupSelection;
}

async function readJSONObject(request: Request): Promise<Record<string, unknown>> {
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

function publicSession(session: SetupSessionRecord): Record<string, unknown> {
    return { id: session.id, state: session.state, expiresAt: session.expires_at };
}

function appClient(env: Env): GitHubAppClient {
    return new GitHubAppClient(
        env.GITHUB_APP_ID,
        env.GITHUB_APP_PRIVATE_KEY,
        env.GITHUB_API_VERSION
    );
}

function publicBaseURL(env: Env): string {
    const url = new URL(env.PUBLIC_BASE_URL);
    return url.toString().replace(/\/$/, "");
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

function bearerToken(header: string | null): string | null {
    const match = header?.match(/^Bearer ([A-Za-z0-9_-]+)$/);
    return match?.[1] ?? null;
}

function randomToken(): string {
    return base64URL(crypto.getRandomValues(new Uint8Array(32)));
}

async function hashToken(value: string): Promise<string> {
    return base64URL(new Uint8Array(await crypto.subtle.digest(
        "SHA-256", new TextEncoder().encode(value)
    )));
}

function base64URL(value: Uint8Array): string {
    return btoa(String.fromCharCode(...value))
        .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function positiveInteger(value: unknown): number | null {
    const number = typeof value === "string" && /^\d+$/.test(value) ? Number(value) : value;
    return typeof number === "number" && Number.isSafeInteger(number) && number > 0 ? number : null;
}

function nonEmptyString(value: unknown): string | null {
    return typeof value === "string" && value.length > 0 ? value : null;
}

function isPositiveInteger(value: unknown): value is number {
    return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}

function isPositiveNumber(value: unknown): value is number {
    return typeof value === "number" && Number.isFinite(value) && value > 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
}

class SetupRequestError extends Error {
    constructor(readonly status: number, readonly code: string) {
        super(code);
    }
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
<title>GitBoard setup</title></head><body><main><h1>GitBoard is connected</h1>
<p>Return to GitBoard to choose a repository and project workflow.</p></main></body></html>`;

const reauthorizationCompleteHTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>GitBoard authorization</title></head><body><main><h1>GitBoard is reauthorized</h1>
<p>You can return to GitBoard.</p></main></body></html>`;
