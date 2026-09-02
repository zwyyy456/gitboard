import { AutomationRunner } from "./automation-runner";
import { GitHubAppClient } from "./github-app-client";
import { GitHubGraphQLClient } from "./github-graphql";
import { GraphQLStatusWriter } from "./graphql-status-writer";
import { OAuthCredentialProvider } from "./oauth-credential-provider";
import { PersonalProjectGateway } from "./personal-project-gateway";
import { RepositoryTruthReader } from "./repository-truth-reader";
import { receiveGitHubWebhook, WebhookRequestError } from "./webhook-receiver";

export interface Env {
    DB: D1Database;
    AUTOMATION_QUEUE: Queue<AutomationMessage>;
    GITHUB_API_VERSION: string;
    GITHUB_APP_ID: string;
    GITHUB_APP_PRIVATE_KEY: string;
    GITHUB_OAUTH_CLIENT_ID: string;
    GITHUB_OAUTH_CLIENT_SECRET: string;
    GITHUB_WEBHOOK_SECRET: string;
    OAUTH_TOKEN_ENCRYPTION_KEY: string;
}

export interface AutomationMessage {
    deliveryID: string;
    installationID: number;
    repositoryID: number;
    pullRequestNumber: number;
    eventAction: string;
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
        return new Response("Not found", { status: 404 });
    },
    async queue(batch, env): Promise<void> {
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
                env.GITHUB_API_VERSION
            )
        );

        for (const message of batch.messages) {
            if (!isAutomationMessage(message.body)) {
                message.ack();
                continue;
            }
            try {
                const decision = await runner.run(message.body, message.attempts);
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
} satisfies ExportedHandler<Env>;

function isAutomationMessage(value: unknown): value is AutomationMessage {
    return typeof value === "object"
        && value !== null
        && "deliveryID" in value
        && typeof value.deliveryID === "string"
        && "installationID" in value
        && isPositiveInteger(value.installationID)
        && "repositoryID" in value
        && isPositiveInteger(value.repositoryID)
        && "pullRequestNumber" in value
        && isPositiveInteger(value.pullRequestNumber)
        && "eventAction" in value
        && typeof value.eventAction === "string";
}

function isPositiveInteger(value: unknown): value is number {
    return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}
