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
} satisfies ExportedHandler<Env>;
