import type { Env } from "./index";
import type { ReviewStatusPolicy } from "./personal-project-gateway";
import { GitHubGraphQLClient } from "./github-graphql";
import { OAuthCredentialProvider } from "./oauth-credential-provider";
import { SetupProjectClient } from "./setup-project-client";
import {
    SetupRequestError, requireConfigurationContext, requireState,
    readJSONObject, secretToken, hashToken, positiveInteger,
    type SetupSessionRecord, type SetupState,
} from "./setup-session";

interface SetupSelectionInput {
    projectNodeID: string;
    projectNumber: number;
    statusFieldNodeID: string;
    inProgressOptionID: string;
    inReviewOptionID: string | null;
    doneOptionID: string;
    reviewStatusPolicy: ReviewStatusPolicy;
}

interface SetupSelection extends Omit<SetupSelectionInput, "inReviewOptionID"> {
    inReviewOptionID: string;
}

export async function recoverSetup(
    request: Request,
    session: SetupSessionRecord,
    env: Env
): Promise<Response> {
    const body = await readJSONObject(request);
    const token = secretToken(body.managementToken);
    if (!token) throw new SetupRequestError(400, "MANAGEMENT_TOKEN_REQUIRED");
    if (session.purpose !== "INITIAL") throw new SetupRequestError(409, "SETUP_STATE_CHANGED");
    const tokenHash = await hashToken(token);
    if (session.state !== "COMPLETE") {
        requireState(session, "RECOVERY_PENDING");
        const context = requireConfigurationContext(session);
        const now = new Date().toISOString();
        // Only the account proven by OAuth and installation ownership can grant access.
        // Keep the existing automation's mapping and enabled state intact.
        await env.DB.batch([
            env.DB.prepare(
                `INSERT INTO management_tokens (id, user_id, token_hash, created_at)
                 SELECT ?, s.user_id, ?, ? FROM setup_sessions s
                 JOIN project_automations a ON a.id = s.automation_id
                    AND a.user_id = s.user_id AND a.installation_id = s.installation_id
                 WHERE s.id = ? AND s.state = 'RECOVERY_PENDING'
                 ON CONFLICT(token_hash) DO NOTHING`
            ).bind(crypto.randomUUID(), tokenHash, now, session.id),
            env.DB.prepare(
                `UPDATE project_automations
                 SET oauth_credential_id = ?, updated_at = ?,
                     health_state = CASE WHEN health_state IN ('OAUTH_REAUTH_REQUIRED', 'OAUTH_SCOPE_MISSING')
                        THEN 'CONTENT_VISIBILITY_UNVERIFIED' ELSE health_state END
                 WHERE id = ? AND user_id = ? AND installation_id = ?
                    AND EXISTS (SELECT 1 FROM setup_sessions s JOIN management_tokens t
                        ON t.user_id = s.user_id AND t.token_hash = ? AND t.revoked_at IS NULL
                        WHERE s.id = ? AND s.state = 'RECOVERY_PENDING')`
            ).bind(context.credentialID, now, session.automation_id, context.userID,
                context.installationID, tokenHash, session.id),
            env.DB.prepare(
                `UPDATE setup_sessions SET state = 'COMPLETE', updated_at = ?,
                    management_token_id = (SELECT id FROM management_tokens
                        WHERE token_hash = ? AND user_id = setup_sessions.user_id AND revoked_at IS NULL)
                 WHERE id = ? AND state = 'RECOVERY_PENDING'
                    AND EXISTS (SELECT 1 FROM management_tokens WHERE token_hash = ?
                        AND user_id = setup_sessions.user_id AND revoked_at IS NULL)
                    AND EXISTS (SELECT 1 FROM project_automations WHERE id = setup_sessions.automation_id
                        AND user_id = setup_sessions.user_id AND installation_id = setup_sessions.installation_id)`
            ).bind(now, tokenHash, session.id, tokenHash),
        ]);
    }
    const completed = await env.DB.prepare(
        `SELECT s.automation_id FROM setup_sessions s JOIN management_tokens t
         ON t.id = s.management_token_id AND t.user_id = s.user_id
         WHERE s.id = ? AND s.state = 'COMPLETE' AND t.token_hash = ? AND t.revoked_at IS NULL`
    ).bind(session.id, tokenHash).first<{ automation_id: string }>();
    if (!completed) throw new SetupRequestError(409, "SETUP_STATE_CHANGED");
    return Response.json({ automationID: completed.automation_id });
}

export async function listSetupOptions(session: SetupSessionRecord, env: Env): Promise<Response> {
    requireState(session, "CONFIGURATION_PENDING");
    requireConfigurationContext(session);
    const projects = await withSetupAccessToken(session, env, (token, ownerLogin, client) => (
        client.listProjects(token, ownerLogin)
    ));
    return Response.json({
        state: session.state,
        projects,
    });
}

export async function listProjectFields(
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

export async function completeSetup(
    request: Request,
    session: SetupSessionRecord,
    env: Env
): Promise<Response> {
    const body = await readJSONObject(request);
    const selectionInput = parseSelection(body);
    const managementToken = secretToken(body.managementToken);
    if (session.purpose === "INITIAL" && !managementToken) {
        throw new SetupRequestError(400, "MANAGEMENT_TOKEN_REQUIRED");
    }
    if (session.purpose !== "INITIAL") {
        throw new SetupRequestError(409, "SETUP_STATE_CHANGED");
    }
    if (session.state === "COMPLETE") {
        const automationID = await requireMatchingCompletion(
            env.DB, session, selectionInput, managementToken
        );
        return Response.json({ automationID });
    }
    requireState(session, "CONFIGURATION_PENDING");
    requireConfigurationContext(session);
    const configuration = await withSetupAccessToken(session, env, async (token, login, client) => {
        await requireSelectedProject(
            client, token, login, selectionInput.projectNodeID, selectionInput.projectNumber
        );
        const fields = await client.listStatusFields(token, login, selectionInput.projectNumber);
        const field = fields.find(
            (candidate) => candidate.nodeID === selectionInput.statusFieldNodeID
        );
        const optionIDs = new Set(field?.options.map((option) => option.id));
        if (!field
            || !optionIDs.has(selectionInput.inProgressOptionID)
            || (selectionInput.inReviewOptionID !== null
                && !optionIDs.has(selectionInput.inReviewOptionID))
            || !optionIDs.has(selectionInput.doneOptionID)) {
            throw new SetupRequestError(400, "INVALID_STATUS_MAPPING");
        }
        await client.requireProjectWriteAccess(token, selectionInput.projectNodeID);
        return {
            ownerLogin: login,
            selection: {
                ...selectionInput,
                inReviewOptionID: selectionInput.inReviewOptionID
                    ?? selectionInput.inProgressOptionID,
            },
        };
    });

    const automationID = await persistSetupCompletion(env.DB, {
        session,
        selection: configuration.selection,
        managementToken,
        projectOwnerLogin: configuration.ownerLogin,
        healthState: "CONTENT_VISIBILITY_UNVERIFIED",
    });
    return Response.json({ automationID });
}

interface CompletionInput {
    session: SetupSessionRecord;
    selection: SetupSelection;
    managementToken: string | null;
    projectOwnerLogin: string;
    healthState: "ACTIVE" | "CONTENT_VISIBILITY_UNVERIFIED";
}

interface CompletedSetupRecord {
    state: SetupState;
    automation_id: string | null;
    management_token_id: string | null;
    token_hash: string | null;
    installation_id: number | null;
    project_node_id: string | null;
    project_number: number | null;
    status_field_node_id: string | null;
    in_progress_option_id: string | null;
    in_review_option_id: string | null;
    done_option_id: string | null;
    review_status_policy: string | null;
}

export async function persistSetupCompletion(
    database: D1Database,
    input: CompletionInput
): Promise<string> {
    const context = requireConfigurationContext(input.session);
    const automationID = crypto.randomUUID();
    const managementTokenID = input.session.purpose === "INITIAL"
        ? crypto.randomUUID()
        : input.session.management_token_id;
    if (!managementTokenID) throw new SetupRequestError(409, "SETUP_STATE_CHANGED");
    const managementTokenHash = input.managementToken
        ? await hashToken(input.managementToken)
        : null;
    if (input.session.purpose === "INITIAL" && !managementTokenHash) {
        throw new SetupRequestError(400, "MANAGEMENT_TOKEN_REQUIRED");
    }
    const now = new Date().toISOString();
    const statements: D1PreparedStatement[] = [];
    if (input.session.purpose === "INITIAL") {
        statements.push(database.prepare(
            `INSERT INTO management_tokens (id, user_id, token_hash, created_at)
             SELECT ?, user_id, ?, ?
             FROM setup_sessions
             WHERE id = ? AND state = 'CONFIGURATION_PENDING' AND purpose = 'INITIAL'`
        ).bind(managementTokenID, managementTokenHash, now, input.session.id));
    }
    statements.push(
        database.prepare(
            `INSERT INTO project_automations (
                id, user_id, oauth_credential_id, installation_id,
                project_owner_login, project_number, project_node_id,
                status_field_node_id, in_progress_option_id, in_review_option_id,
                done_option_id, review_status_policy, enabled, health_state,
                created_at, updated_at
             )
             SELECT ?, user_id, oauth_credential_id, installation_id,
                    ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?
             FROM setup_sessions
             WHERE id = ? AND state = 'CONFIGURATION_PENDING'`
        ).bind(
            automationID,
            input.projectOwnerLogin, input.selection.projectNumber,
            input.selection.projectNodeID, input.selection.statusFieldNodeID,
            input.selection.inProgressOptionID, input.selection.inReviewOptionID,
            input.selection.doneOptionID, input.selection.reviewStatusPolicy,
            input.healthState, now, now,
            input.session.id
        ),
        database.prepare(
            `UPDATE setup_sessions
             SET automation_id = ?, management_token_id = ?, state = 'COMPLETE', updated_at = ?
             WHERE id = ? AND state = 'CONFIGURATION_PENDING'`
        ).bind(automationID, managementTokenID, now, input.session.id)
    );

    try {
        await database.batch(statements);
    } catch (error) {
        const completed = await matchingCompletion(
            database, input.session, input.selection, managementTokenHash
        );
        if (completed) return completed;
        const existing = await database.prepare(
            `SELECT id FROM project_automations
             WHERE installation_id = ?`
        ).bind(context.installationID)
            .first<{ id: string }>();
        if (existing) {
            throw new SetupRequestError(409, "ACCOUNT_AUTOMATION_ALREADY_CONFIGURED");
        }
        throw error;
    }

    const completed = await matchingCompletion(
        database, input.session, input.selection, managementTokenHash
    );
    if (!completed) throw new SetupRequestError(409, "SETUP_STATE_CHANGED");
    return completed;
}

async function requireMatchingCompletion(
    database: D1Database,
    session: SetupSessionRecord,
    selection: SetupSelectionInput,
    managementToken: string | null
): Promise<string> {
    const tokenHash = managementToken ? await hashToken(managementToken) : null;
    const automationID = await matchingCompletion(database, session, selection, tokenHash);
    if (!automationID) throw new SetupRequestError(409, "SETUP_STATE_CHANGED");
    return automationID;
}

async function matchingCompletion(
    database: D1Database,
    session: SetupSessionRecord,
    selection: SetupSelectionInput,
    managementTokenHash: string | null
): Promise<string | null> {
    const completed = await database.prepare(
        `SELECT session.state, session.automation_id, session.management_token_id,
                token.token_hash, automation.installation_id,
                automation.project_node_id, automation.project_number,
                automation.status_field_node_id, automation.in_progress_option_id,
                automation.in_review_option_id, automation.done_option_id,
                automation.review_status_policy
         FROM setup_sessions session
         LEFT JOIN project_automations automation ON automation.id = session.automation_id
         LEFT JOIN management_tokens token ON token.id = session.management_token_id
         WHERE session.id = ?`
    ).bind(session.id).first<CompletedSetupRecord>();
    if (!completed
        || completed.state !== "COMPLETE"
        || !completed.automation_id
        || completed.installation_id !== session.installation_id
        || completed.project_node_id !== selection.projectNodeID
        || completed.project_number !== selection.projectNumber
        || completed.status_field_node_id !== selection.statusFieldNodeID
        || completed.in_progress_option_id !== selection.inProgressOptionID
        || (selection.inReviewOptionID !== null
            && completed.in_review_option_id !== selection.inReviewOptionID)
        || completed.done_option_id !== selection.doneOptionID
        || completed.review_status_policy !== selection.reviewStatusPolicy) {
        return null;
    }
    if (session.purpose === "INITIAL") {
        if (!managementTokenHash || completed.token_hash !== managementTokenHash) return null;
    } else if (completed.management_token_id !== session.management_token_id) {
        return null;
    }
    return completed.automation_id;
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

function parseSelection(body: Record<string, unknown>): SetupSelectionInput {
    const inProgressOptionID = nonEmptyString(body.inProgressOptionID);
    const inReviewOptionID = body.inReviewOptionID === undefined
        || body.inReviewOptionID === null
        ? null
        : nonEmptyString(body.inReviewOptionID);
    const reviewStatusPolicy = parseReviewStatusPolicy(
        body.reviewStatusPolicy,
        inReviewOptionID
    );
    const selection = {
        projectNodeID: nonEmptyString(body.projectNodeID),
        projectNumber: positiveInteger(body.projectNumber),
        statusFieldNodeID: nonEmptyString(body.statusFieldNodeID),
        inProgressOptionID,
        inReviewOptionID,
        doneOptionID: nonEmptyString(body.doneOptionID),
        reviewStatusPolicy,
    };
    if (!selection.projectNodeID
        || !selection.projectNumber
        || !selection.statusFieldNodeID
        || !selection.inProgressOptionID
        || !selection.doneOptionID) {
        throw new SetupRequestError(400, "INVALID_SELECTION");
    }
    return selection as SetupSelectionInput;
}

function parseReviewStatusPolicy(
    value: unknown,
    legacyReviewOptionID: string | null
): ReviewStatusPolicy {
    if (value === undefined) {
        return legacyReviewOptionID === null
            ? "ENSURE_IN_REVIEW"
            : "USE_CONFIGURED_OPTION";
    }
    if (value === "ENSURE_IN_REVIEW" || value === "USE_IN_PROGRESS") return value;
    throw new SetupRequestError(400, "INVALID_SELECTION");
}

function nonEmptyString(value: unknown): string | null {
    return typeof value === "string" && value.length > 0 ? value : null;
}
