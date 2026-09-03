const githubAPI = "https://api.github.com";

export type GitHubProjectsRESTErrorCode =
    | "AUTH_REQUIRED"
    | "SCOPE_MISSING"
    | "FORBIDDEN"
    | "NOT_FOUND"
    | "TRANSIENT"
    | "INCOMPATIBLE";

export class GitHubProjectsRESTError extends Error {
    constructor(
        readonly code: GitHubProjectsRESTErrorCode,
        readonly status?: number
    ) {
        super(code);
    }
}

export class GitHubProjectsRESTClient {
    constructor(private readonly apiVersion: string) {}

    async requestPage(
        url: string,
        accessToken: string
    ): Promise<{ body: unknown[]; nextPage: string | null }> {
        let response: Response;
        try {
            response = await fetch(url, {
                headers: {
                    Accept: "application/vnd.github+json",
                    Authorization: `Bearer ${accessToken}`,
                    "User-Agent": "GitBoard-Automation",
                    "X-GitHub-Api-Version": this.apiVersion,
                },
            });
        } catch {
            throw new GitHubProjectsRESTError("TRANSIENT");
        }

        if (!response.ok) throw classifyFailure(response);
        if (!hasProjectScope(response.headers.get("X-OAuth-Scopes"))) {
            throw new GitHubProjectsRESTError("SCOPE_MISSING", response.status);
        }

        let body: unknown;
        try {
            body = await response.json();
        } catch {
            throw new GitHubProjectsRESTError("INCOMPATIBLE", 502);
        }
        if (!Array.isArray(body)) {
            throw new GitHubProjectsRESTError("INCOMPATIBLE", 502);
        }
        return { body, nextPage: readNextPage(response.headers.get("Link")) };
    }
}

export function githubProjectsURL(path: string): URL {
    return new URL(path, githubAPI);
}

function classifyFailure(response: Response): GitHubProjectsRESTError {
    const status = response.status;
    if (status === 401) return new GitHubProjectsRESTError("AUTH_REQUIRED", status);
    if (status === 403 && isRateLimited(response.headers)) {
        return new GitHubProjectsRESTError("TRANSIENT", status);
    }
    if (status === 403 && !hasProjectScope(response.headers.get("X-OAuth-Scopes"))) {
        return new GitHubProjectsRESTError("SCOPE_MISSING", status);
    }
    if (status === 403) return new GitHubProjectsRESTError("FORBIDDEN", status);
    if (status === 404) return new GitHubProjectsRESTError("NOT_FOUND", status);
    if (status === 429 || status >= 500) {
        return new GitHubProjectsRESTError("TRANSIENT", status);
    }
    return new GitHubProjectsRESTError("INCOMPATIBLE", status);
}

function readNextPage(linkHeader: string | null): string | null {
    if (!linkHeader) return null;
    for (const value of linkHeader.split(",")) {
        const match = value.match(/<([^>]+)>;\s*rel="next"/);
        if (!match) {
            if (value.includes("rel=\"next\"")) {
                throw new GitHubProjectsRESTError("INCOMPATIBLE", 502);
            }
            continue;
        }
        let url: URL;
        try {
            url = new URL(match[1]);
        } catch {
            throw new GitHubProjectsRESTError("INCOMPATIBLE", 502);
        }
        if (url.origin !== githubAPI) {
            throw new GitHubProjectsRESTError("INCOMPATIBLE", 502);
        }
        return url.toString();
    }
    return null;
}

function hasProjectScope(value: string | null): boolean {
    return (value ?? "")
        .split(",")
        .map((scope) => scope.trim())
        .includes("project");
}

function isRateLimited(headers: Headers): boolean {
    return headers.has("Retry-After") || headers.get("X-RateLimit-Remaining") === "0";
}
