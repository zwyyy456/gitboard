import type { Env } from "./index";
import { SetupRequestError, publicBaseURL, isRecord } from "./setup-session";
const githubOAuthEndpoint = "https://github.com/login/oauth";

export interface GitHubOAuthToken {
    accessToken: string;
    refreshToken: string;
    accessTokenExpiresAt: string;
    refreshTokenExpiresAt: string;
}

export interface GitHubUser {
    databaseID: number;
    nodeID: string;
    login: string;
    scopes: string[];
}

const githubAPI = "https://api.github.com";

export async function exchangeOAuthCode(code: string, env: Env): Promise<GitHubOAuthToken> {
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

export async function loadGitHubUser(accessToken: string, apiVersion: string): Promise<GitHubUser> {
    let response: Response;
    try {
        response = await fetch(`${githubAPI}/user`, {
            headers: {
                Accept: "application/vnd.github+json",
                Authorization: `Bearer ${accessToken}`,
                "User-Agent": "GitStride-Automation",
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

function isPositiveInteger(value: unknown): value is number {
    return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}

function isPositiveNumber(value: unknown): value is number {
    return typeof value === "number" && Number.isFinite(value) && value > 0;
}
