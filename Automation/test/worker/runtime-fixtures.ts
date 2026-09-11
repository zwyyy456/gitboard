import { env } from "cloudflare:workers";
import { applyD1Migrations, type D1Migration } from "cloudflare:test";
import type { DeliveryMessage } from "../../src/index";
import type { Env } from "../../src/index";
import type { ReviewStatusPolicy } from "../../src/personal-project-gateway";

interface TestEnvironment extends Env {
    TEST_MIGRATIONS: D1Migration[];
}

export const testEnv = env as TestEnvironment;

export async function initializeDatabase() {
    await applyD1Migrations(testEnv.DB, testEnv.TEST_MIGRATIONS);
}

export function queueThat(
    send: (message: DeliveryMessage) => Promise<void>
): Queue<DeliveryMessage> {
    return { send } as unknown as Queue<DeliveryMessage>;
}

export async function nextWebSocketMessage(socket: WebSocket): Promise<unknown> {
    return new Promise((resolve, reject) => {
        socket.addEventListener("message", (event) => {
            try {
                resolve(JSON.parse(String(event.data)));
            } catch (error) {
                reject(error);
            }
        }, { once: true });
        socket.addEventListener("error", () => reject(new Error("websocket failed")), {
            once: true,
        });
    });
}

export function environmentWith(queue: Queue<DeliveryMessage>): Env {
    return {
        DB: testEnv.DB,
        AUTOMATION_QUEUE: queue,
        AUTOMATION_EVENTS: testEnv.AUTOMATION_EVENTS,
        GITHUB_API_VERSION: "2026-03-10",
        GITHUB_APP_ID: "unused",
        GITHUB_APP_PRIVATE_KEY: "unused",
        GITHUB_OAUTH_CLIENT_ID: "unused",
        GITHUB_OAUTH_CLIENT_SECRET: "unused",
        GITHUB_APP_SLUG: "unused",
        GITHUB_WEBHOOK_SECRET: "unused",
        OAUTH_TOKEN_ENCRYPTION_KEY: "unused",
        PUBLIC_BASE_URL: "https://example.invalid",
    };
}

export async function pullRequestWebhookRequest(
    deliveryID: string,
    installationID: number,
    repositoryID: number
): Promise<Request> {
    const body = JSON.stringify({
        action: "opened",
        installation: { id: installationID },
        repository: { id: repositoryID },
        pull_request: { number: 1 },
    });
    const key = await crypto.subtle.importKey(
        "raw",
        new TextEncoder().encode("unused"),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["sign"]
    );
    const signature = new Uint8Array(await crypto.subtle.sign(
        "HMAC",
        key,
        new TextEncoder().encode(body)
    ));
    const hexadecimal = [...signature]
        .map((byte) => byte.toString(16).padStart(2, "0"))
        .join("");
    return new Request("https://example.invalid/webhooks/github", {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
            "X-GitHub-Delivery": deliveryID,
            "X-GitHub-Event": "pull_request",
            "X-Hub-Signature-256": `sha256=${hexadecimal}`,
        },
        body,
    });
}

export async function deliveryState(deliveryID: string): Promise<string | null> {
    const delivery = await testEnv.DB.prepare(
        "SELECT processing_state FROM webhook_deliveries WHERE delivery_id = ?"
    ).bind(deliveryID).first<{ processing_state: string }>();
    return delivery?.processing_state ?? null;
}

export async function seedCompletedAutomationDelivery(): Promise<void> {
    const now = new Date().toISOString();
    await testEnv.DB.batch([
        userInsertion(now),
        testEnv.DB.prepare(
            `INSERT INTO oauth_credentials (
                id, user_id, encrypted_access_token, encrypted_refresh_token,
                access_token_expires_at, refresh_token_expires_at, granted_scopes,
                credential_version, health_state, updated_at
             ) VALUES (
                'credential', 'user', 'access', 'refresh', ?, ?, '["project"]', 1, 'ACTIVE', ?
             )`
        ).bind(now, now, now),
        testEnv.DB.prepare(
            `INSERT INTO installations (
                installation_id, user_id, github_account_id, status, updated_at
             ) VALUES (7, 'user', 1, 'ACTIVE', ?)`
        ).bind(now),
        testEnv.DB.prepare(
            `INSERT INTO installation_repositories (
                installation_id, repository_id, repository_node_id, name_with_owner, updated_at
             ) VALUES (7, 11, 'REPOSITORY_NODE', 'owner/repository', ?)`
        ).bind(now),
        testEnv.DB.prepare(
            `INSERT INTO project_automations (
                id, user_id, oauth_credential_id, installation_id,
                project_owner_login, project_number,
                project_node_id, status_field_node_id, in_progress_option_id,
                in_review_option_id, done_option_id, enabled, health_state,
                created_at, updated_at
             ) VALUES (
                'automation', 'user', 'credential', 7,
                'owner', 1, 'PROJECT', 'FIELD', 'PROGRESS', 'REVIEW', 'DONE',
                1, 'ACTIVE', ?, ?
             )`
        ).bind(now, now),
        testEnv.DB.prepare(
            `INSERT INTO webhook_deliveries (
                delivery_id, automation_id, installation_id, repository_id,
                pull_request_number, event_name, event_action, processing_state,
                received_at, state_updated_at, completed_at
             ) VALUES (
                'delivery-terminal', 'automation', 7, 11, 42, 'pull_request',
                'closed', 'COMPLETED', ?, ?, ?
             )`
        ).bind(now, now, now),
    ]);
}

export async function seedUser(): Promise<void> {
    const now = new Date().toISOString();
    await userInsertion(now).run();
}

function userInsertion(now: string): D1PreparedStatement {
    return testEnv.DB.prepare(
        `INSERT OR IGNORE INTO users (
            id, github_user_node_id, github_user_database_id, github_login, created_at, updated_at
         ) VALUES ('user', 'USER_NODE', 1, 'owner', ?, ?)`
    ).bind(now, now);
}

export async function seedConfigurableSetup(suffix: string, installationID: number) {
    const now = new Date().toISOString();
    const userID = `user-${suffix}`;
    const credentialID = `credential-${suffix}`;
    const sessionID = `setup-${suffix}`;
    await testEnv.DB.batch([
        testEnv.DB.prepare(
            `INSERT INTO users (
                id, github_user_node_id, github_user_database_id, github_login,
                created_at, updated_at
             ) VALUES (?, ?, ?, 'owner', ?, ?)`
        ).bind(userID, `USER-${suffix}`, installationID, now, now),
        testEnv.DB.prepare(
            `INSERT INTO oauth_credentials (
                id, user_id, encrypted_access_token, encrypted_refresh_token,
                access_token_expires_at, refresh_token_expires_at, granted_scopes,
                credential_version, health_state, updated_at
             ) VALUES (?, ?, 'access', 'refresh', ?, ?, '["project"]', 1, 'ACTIVE', ?)`
        ).bind(credentialID, userID, now, now, now),
        testEnv.DB.prepare(
            `INSERT INTO installations (
                installation_id, user_id, github_account_id, status, updated_at
             ) VALUES (?, ?, ?, 'ACTIVE', ?)`
        ).bind(installationID, userID, installationID, now),
        testEnv.DB.prepare(
            `INSERT INTO setup_sessions (
                id, setup_token_hash, user_id, oauth_credential_id, installation_id,
                state, expires_at, created_at, updated_at, purpose
             ) VALUES (?, ?, ?, ?, ?, 'CONFIGURATION_PENDING', ?, ?, ?, 'INITIAL')`
        ).bind(
            sessionID, `setup-token-${suffix}`, userID, credentialID, installationID,
            new Date(Date.now() + 60_000).toISOString(), now, now
        ),
    ]);
    return {
        id: sessionID,
        setup_token_hash: `setup-token-${suffix}`,
        user_id: userID,
        oauth_credential_id: credentialID,
        installation_id: installationID,
        state: "CONFIGURATION_PENDING" as const,
        expires_at: new Date(Date.now() + 60_000).toISOString(),
        purpose: "INITIAL" as const,
        management_token_id: null,
    };
}

export function completionInput(
    session: Awaited<ReturnType<typeof seedConfigurableSetup>>,
    repositoryID: number,
    managementToken: string,
    reviewStatusPolicy: ReviewStatusPolicy = "USE_CONFIGURED_OPTION"
) {
    return {
        session,
        selection: {
            projectNodeID: `PROJECT-${repositoryID}`,
            projectNumber: repositoryID,
            statusFieldNodeID: `FIELD-${repositoryID}`,
            inProgressOptionID: `PROGRESS-${repositoryID}`,
            inReviewOptionID: `REVIEW-${repositoryID}`,
            doneOptionID: `DONE-${repositoryID}`,
            reviewStatusPolicy,
        },
        managementToken,
        projectOwnerLogin: "owner",
        healthState: "ACTIVE" as const,
    };
}

export async function setupCompletionCounts(suffix: string) {
    const userID = `user-${suffix}`;
    const result = await testEnv.DB.prepare(
        `SELECT
            (SELECT COUNT(*) FROM project_automations WHERE user_id = ?) AS automations,
            (SELECT COUNT(*) FROM management_tokens WHERE user_id = ?) AS tokens`
    ).bind(userID, userID).first<{ automations: number; tokens: number }>();
    return result ?? { automations: 0, tokens: 0 };
}

export async function tokenHash(value: string): Promise<string> {
    const hash = new Uint8Array(await crypto.subtle.digest(
        "SHA-256", new TextEncoder().encode(value)
    ));
    return btoa(String.fromCharCode(...hash))
        .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

export async function seedMaintenanceSetup(
    suffix: string,
    installationID: number,
    expiresAt: string
): Promise<void> {
    const now = "2026-08-01T00:00:00.000Z";
    await testEnv.DB.batch([
        testEnv.DB.prepare(
            `INSERT INTO users (
                id, github_user_node_id, github_user_database_id, github_login,
                created_at, updated_at
             ) VALUES (?, ?, ?, 'owner', ?, ?)`
        ).bind(`user-${suffix}`, `USER-${suffix}`, installationID, now, now),
        credentialInsertion(`credential-${suffix}`, `user-${suffix}`, now),
        installationInsertion(installationID, `user-${suffix}`, now),
        testEnv.DB.prepare(
            `INSERT INTO setup_sessions (
                id, setup_token_hash, user_id, oauth_credential_id, installation_id,
                state, expires_at, created_at, updated_at, purpose
             ) VALUES (?, ?, ?, ?, ?, 'INSTALLATION_PENDING', ?, ?, ?, 'INITIAL')`
        ).bind(
            `setup-${suffix}`, `setup-token-${suffix}`, `user-${suffix}`,
            `credential-${suffix}`, installationID, expiresAt, now, now
        ),
    ]);
}

export function credentialInsertion(id: string, userID: string, now: string): D1PreparedStatement {
    return testEnv.DB.prepare(
        `INSERT INTO oauth_credentials (
            id, user_id, encrypted_access_token, encrypted_refresh_token,
            access_token_expires_at, refresh_token_expires_at, granted_scopes,
            credential_version, health_state, updated_at
         ) VALUES (?, ?, 'access', 'refresh', ?, ?, '["project"]', 1, 'ACTIVE', ?)`
    ).bind(id, userID, now, now, now);
}

export function installationInsertion(
    installationID: number,
    userID: string,
    now: string
): D1PreparedStatement {
    return testEnv.DB.prepare(
        `INSERT INTO installations (
            installation_id, user_id, github_account_id, status, updated_at
         ) VALUES (?, ?, ?, 'ACTIVE', ?)`
    ).bind(installationID, userID, installationID, now);
}

export function maintenanceDelivery(
    id: string,
    state: string,
    stateUpdatedAt: string,
    completedAt: string | null
): D1PreparedStatement {
    return testEnv.DB.prepare(
        `INSERT INTO webhook_deliveries (
            delivery_id, installation_id, event_name, event_action, processing_state,
            received_at, state_updated_at, completed_at
         ) VALUES (?, 999, 'installation', 'created', ?, ?, ?, ?)`
    ).bind(id, state, stateUpdatedAt, stateUpdatedAt, completedAt);
}

export async function maintenanceObjectCounts(suffix: string, installationID: number) {
    const result = await testEnv.DB.prepare(
        `SELECT
            (SELECT COUNT(*) FROM users WHERE id = ?) AS users,
            (SELECT COUNT(*) FROM oauth_credentials WHERE id = ?) AS credentials,
            (SELECT COUNT(*) FROM installations WHERE installation_id = ?) AS installations,
            (SELECT COUNT(*) FROM setup_sessions WHERE id = ?) AS sessions`
    ).bind(
        `user-${suffix}`,
        `credential-${suffix}`,
        installationID,
        `setup-${suffix}`
    ).first<{
        users: number;
        credentials: number;
        installations: number;
        sessions: number;
    }>();
    return result ?? { users: 0, credentials: 0, installations: 0, sessions: 0 };
}
