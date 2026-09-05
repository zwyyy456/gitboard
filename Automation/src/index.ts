import { AutomationRunner } from "./automation-runner";
import {
    AutomationEvents,
    DurableObjectAutomationChangeNotifier,
    handleAutomationEventsRequest,
} from "./automation-events";
import { failExhaustedDelivery, flushDeliveryOutbox } from "./delivery-outbox";
import { GitHubAppClient } from "./github-app-client";
import { GitHubGraphQLClient } from "./github-graphql";
import { GraphQLStatusWriter } from "./graphql-status-writer";
import { InstallationLifecycleRunner } from "./installation-lifecycle";
import { runMaintenance } from "./maintenance";
import { OAuthCredentialProvider } from "./oauth-credential-provider";
import { PersonalProjectGateway } from "./personal-project-gateway";
import { RepositoryTruthReader } from "./repository-truth-reader";
import { SetupProjectClient } from "./setup-project-client";
import { handleManagementRequest } from "./management-api";
import { handleSetupRequest } from "./setup-api";
import { receiveGitHubWebhook, WebhookRequestError } from "./webhook-receiver";

export interface Env {
    DB: D1Database;
    AUTOMATION_QUEUE: Queue<DeliveryMessage>;
    AUTOMATION_EVENTS: DurableObjectNamespace<AutomationEvents>;
    GITHUB_API_VERSION: string;
    GITHUB_APP_ID: string;
    GITHUB_APP_PRIVATE_KEY: string;
    GITHUB_OAUTH_CLIENT_ID: string;
    GITHUB_OAUTH_CLIENT_SECRET: string;
    GITHUB_APP_SLUG: string;
    GITHUB_WEBHOOK_SECRET: string;
    OAUTH_TOKEN_ENCRYPTION_KEY: string;
    PUBLIC_BASE_URL: string;
}

export interface DeliveryMessage {
    deliveryID: string;
}

export default {
    async fetch(request, env): Promise<Response> {
        const url = new URL(request.url);
        if (request.method === "GET" && url.pathname === "/health") {
            return Response.json({ status: "ok" });
        }
        if (request.method === "POST" && url.pathname === "/webhooks/github") {
            try {
                return await receiveGitHubWebhook(request, env);
            } catch (error) {
                if (error instanceof WebhookRequestError) {
                    return Response.json({ error: error.code }, { status: error.status });
                }
                return Response.json({ error: "WEBHOOK_UNAVAILABLE" }, { status: 503 });
            }
        }
        if (url.pathname === "/api/events") {
            return handleAutomationEventsRequest(request, env);
        }
        if (url.pathname.startsWith("/api/setup/")
            || url.pathname === "/api/setup/sessions"
            || /^\/setup\/[^/]+\/oauth$/.test(url.pathname)
            || url.pathname === "/oauth/callback"
            || url.pathname === "/setup/github-app") {
            return handleSetupRequest(request, env);
        }
        if (url.pathname === "/api/automations" || url.pathname.startsWith("/api/automations/")) {
            return handleManagementRequest(request, env);
        }
        return new Response("Not found", { status: 404 });
    },
    async queue(batch, env): Promise<void> {
        if (batch.queue === "gitboard-automation-dlq") {
            for (const message of batch.messages) {
                if (isDeliveryMessage(message.body)) {
                    await failExhaustedDelivery(env.DB, message.body.deliveryID);
                }
                message.ack();
            }
            return;
        }

        const graphQL = new GitHubGraphQLClient(env.GITHUB_API_VERSION);
        const appClient = new GitHubAppClient(
            env.GITHUB_APP_ID,
            env.GITHUB_APP_PRIVATE_KEY,
            env.GITHUB_API_VERSION
        );
        const accessTokens = new OAuthCredentialProvider(env.DB, {
            clientID: env.GITHUB_OAUTH_CLIENT_ID,
            clientSecret: env.GITHUB_OAUTH_CLIENT_SECRET,
            encryptionKey: env.OAUTH_TOKEN_ENCRYPTION_KEY,
            apiVersion: env.GITHUB_API_VERSION,
        });
        const runner = new AutomationRunner(
            env.DB,
            new RepositoryTruthReader(appClient, graphQL),
            new PersonalProjectGateway(
                accessTokens,
                new GraphQLStatusWriter(graphQL),
                new SetupProjectClient(graphQL, env.GITHUB_API_VERSION),
                env.GITHUB_API_VERSION
            ),
            new DurableObjectAutomationChangeNotifier(env.AUTOMATION_EVENTS)
        );
        const installationRunner = new InstallationLifecycleRunner(env.DB, appClient);

        for (const message of batch.messages) {
            if (!isDeliveryMessage(message.body)) {
                message.ack();
                continue;
            }
            try {
                const delivery = await env.DB.prepare(
                    "SELECT event_name FROM webhook_deliveries WHERE delivery_id = ?"
                ).bind(message.body.deliveryID).first<{ event_name: string }>();
                if (!delivery) {
                    message.ack();
                    continue;
                }
                const decision = delivery.event_name === "installation"
                    || delivery.event_name === "installation_repositories"
                    ? await installationRunner.run(message.body.deliveryID, message.attempts)
                    : await runner.run(message.body, message.attempts);
                if (decision.action === "ack") {
                    message.ack();
                } else {
                    message.retry({ delaySeconds: decision.delaySeconds });
                }
            } catch {
                message.retry({ delaySeconds: 60 });
            }
        }
    },
    async scheduled(controller, env): Promise<void> {
        await flushDeliveryOutbox(env.DB, env.AUTOMATION_QUEUE);
        if (controller.cron === "0 3 * * *") {
            await runMaintenance(env.DB);
        }
    },
} satisfies ExportedHandler<Env>;

export { AutomationEvents };

function isDeliveryMessage(value: unknown): value is DeliveryMessage {
    return typeof value === "object"
        && value !== null
        && "deliveryID" in value
        && typeof value.deliveryID === "string";
}
