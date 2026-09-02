const graphQLEndpoint = "https://api.github.com/graphql";

export type GitHubGraphQLErrorKind =
    | "AUTHENTICATION"
    | "FORBIDDEN"
    | "NOT_FOUND"
    | "TRANSIENT"
    | "INVALID_RESPONSE";

export class GitHubGraphQLError extends Error {
    constructor(
        readonly kind: GitHubGraphQLErrorKind,
        readonly status?: number
    ) {
        super(`GitHub GraphQL request failed: ${kind}`);
    }
}

export interface GraphQLRequester {
    request<T>(token: string, query: string, variables: Record<string, unknown>): Promise<T>;
}

export class GitHubGraphQLClient implements GraphQLRequester {
    constructor(private readonly apiVersion: string) {}

    async request<T>(
        token: string,
        query: string,
        variables: Record<string, unknown>
    ): Promise<T> {
        let response: Response;
        try {
            response = await fetch(graphQLEndpoint, {
                method: "POST",
                headers: {
                    Accept: "application/vnd.github+json",
                    Authorization: `Bearer ${token}`,
                    "Content-Type": "application/json",
                    "User-Agent": "GitBoard-Automation",
                    "X-GitHub-Api-Version": this.apiVersion,
                },
                body: JSON.stringify({ query, variables }),
            });
        } catch {
            throw new GitHubGraphQLError("TRANSIENT");
        }
        if (!response.ok) {
            throw new GitHubGraphQLError(
                classifyHTTPStatus(response.status, response.headers),
                response.status
            );
        }

        let body: unknown;
        try {
            body = await response.json();
        } catch {
            throw new GitHubGraphQLError("INVALID_RESPONSE", 502);
        }
        if (!isRecord(body)) {
            throw new GitHubGraphQLError("INVALID_RESPONSE", 502);
        }
        if (Array.isArray(body.errors) && body.errors.length > 0) {
            throw new GitHubGraphQLError(classifyGraphQLErrors(body.errors));
        }
        if (!("data" in body)) {
            throw new GitHubGraphQLError("INVALID_RESPONSE", 502);
        }
        return body.data as T;
    }
}

function classifyHTTPStatus(status: number, headers: Headers): GitHubGraphQLErrorKind {
    if (status === 401) return "AUTHENTICATION";
    if (status === 403
        && (headers.has("Retry-After") || headers.get("X-RateLimit-Remaining") === "0")) {
        return "TRANSIENT";
    }
    if (status === 403) return "FORBIDDEN";
    if (status === 404) return "NOT_FOUND";
    if (status === 429 || status >= 500) return "TRANSIENT";
    return "INVALID_RESPONSE";
}

function classifyGraphQLErrors(errors: unknown[]): GitHubGraphQLErrorKind {
    const types = errors.flatMap((error) => (
        isRecord(error) && typeof error.type === "string" ? [error.type] : []
    ));
    if (types.includes("FORBIDDEN")) return "FORBIDDEN";
    if (types.includes("NOT_FOUND")) return "NOT_FOUND";
    if (types.includes("RATE_LIMITED")) return "TRANSIENT";
    return "INVALID_RESPONSE";
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
}
