export interface Env {
    DB: D1Database;
    GITHUB_API_VERSION: string;
    GITHUB_APP_ID: string;
    GITHUB_APP_PRIVATE_KEY: string;
    GITHUB_OAUTH_CLIENT_ID: string;
    GITHUB_OAUTH_CLIENT_SECRET: string;
    GITHUB_WEBHOOK_SECRET: string;
    OAUTH_TOKEN_ENCRYPTION_KEY: string;
}

export default {
    async fetch(request): Promise<Response> {
        const url = new URL(request.url);
        if (request.method === "GET" && url.pathname === "/health") {
            return Response.json({ status: "ok" });
        }
        return new Response("Not found", { status: 404 });
    },
} satisfies ExportedHandler<Env>;
