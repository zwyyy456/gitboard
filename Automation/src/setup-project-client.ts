import type { GraphQLRequester } from "./github-graphql";

const githubAPI = "https://api.github.com";

export interface SetupProject {
    nodeID: string;
    number: number;
    title: string;
}

export interface SetupStatusField {
    nodeID: string;
    name: string;
    options: Array<{ id: string; name: string }>;
}

export type ContentVisibilityProbe = "VERIFIED" | "UNVERIFIED";

export type SetupProjectErrorCode =
    | "OAUTH_REAUTH_REQUIRED"
    | "OAUTH_SCOPE_MISSING"
    | "PROJECT_WRITE_FORBIDDEN"
    | "PROJECT_API_INCOMPATIBLE"
    | "TRANSIENT_GITHUB_FAILURE";

export class SetupProjectError extends Error {
    constructor(readonly code: SetupProjectErrorCode, readonly status?: number) {
        super(code);
    }
}

export class SetupProjectClient {
    constructor(
        private readonly graphQL: GraphQLRequester,
        private readonly apiVersion: string
    ) {}

    async listProjects(accessToken: string, ownerLogin: string): Promise<SetupProject[]> {
        const projects: SetupProject[] = [];
        let url: string | null = new URL(
            `/users/${encodeURIComponent(ownerLogin)}/projectsV2?per_page=100`,
            githubAPI
        ).toString();

        while (url) {
            const page = await this.requestPage(url, accessToken);
            for (const value of page.body) {
                if (!isRecord(value)
                    || typeof value.node_id !== "string"
                    || !isPositiveInteger(value.number)
                    || typeof value.title !== "string"
                    || !isRecord(value.owner)
                    || value.owner.login !== ownerLogin) {
                    throw new SetupProjectError("PROJECT_API_INCOMPATIBLE");
                }
                projects.push({
                    nodeID: value.node_id,
                    number: value.number,
                    title: value.title,
                });
            }
            url = page.nextPage;
        }
        return projects;
    }

    async listStatusFields(
        accessToken: string,
        ownerLogin: string,
        projectNumber: number
    ): Promise<SetupStatusField[]> {
        const fields: SetupStatusField[] = [];
        let url: string | null = new URL(
            `/users/${encodeURIComponent(ownerLogin)}/projectsV2/${projectNumber}/fields?per_page=100`,
            githubAPI
        ).toString();

        while (url) {
            const page = await this.requestPage(url, accessToken);
            for (const value of page.body) {
                if (!isRecord(value) || value.data_type !== "single_select") {
                    continue;
                }
                if (typeof value.node_id !== "string"
                    || typeof value.name !== "string"
                    || !Array.isArray(value.options)) {
                    throw new SetupProjectError("PROJECT_API_INCOMPATIBLE");
                }
                const options = value.options.map((option) => {
                    if (!isRecord(option)
                        || typeof option.id !== "string"
                        || !isRecord(option.name)
                        || typeof option.name.raw !== "string") {
                        throw new SetupProjectError("PROJECT_API_INCOMPATIBLE");
                    }
                    return { id: option.id, name: option.name.raw };
                });
                fields.push({ nodeID: value.node_id, name: value.name, options });
            }
            url = page.nextPage;
        }
        return fields;
    }

    async requireProjectWriteAccess(accessToken: string, projectNodeID: string): Promise<void> {
        const data = await this.graphQL.request<{
            node: null | { id: string; viewerCanUpdate: boolean };
        }>(accessToken, `
            query SetupProjectAccess($projectID: ID!) {
                node(id: $projectID) {
                    ... on ProjectV2 {
                        id
                        viewerCanUpdate
                    }
                }
            }
        `, { projectID: projectNodeID });
        if (!data.node || data.node.id !== projectNodeID || data.node.viewerCanUpdate !== true) {
            throw new SetupProjectError("PROJECT_WRITE_FORBIDDEN");
        }
    }

    async probeContentVisibility(
        oauthToken: string,
        installationToken: string,
        ownerLogin: string,
        projectNumber: number,
        repositoryNameWithOwner: string
    ): Promise<ContentVisibilityProbe> {
        const issueNodeIDs: string[] = [];
        const itemsURL = new URL(
            `/users/${encodeURIComponent(ownerLogin)}/projectsV2/${projectNumber}/items`,
            githubAPI
        );
        itemsURL.searchParams.set("q", `repo:${repositoryNameWithOwner} is:issue`);
        itemsURL.searchParams.set("per_page", "100");
        const page = await this.requestPage(itemsURL.toString(), oauthToken);
        for (const value of page.body) {
            if (!isRecord(value)) throw new SetupProjectError("PROJECT_API_INCOMPATIBLE");
            if (isRecord(value.content) && typeof value.content.node_id === "string") {
                issueNodeIDs.push(value.content.node_id);
            }
        }
        if (issueNodeIDs.length === 0) return "UNVERIFIED";

        const data = await this.graphQL.request<{
            nodes: unknown;
        }>(installationToken, `
            query SetupContentVisibility($issueIDs: [ID!]!) {
                nodes(ids: $issueIDs) {
                    ... on Issue {
                        id
                        repository { nameWithOwner isPrivate }
                    }
                }
            }
        `, { issueIDs: issueNodeIDs });
        if (!Array.isArray(data.nodes)) throw new SetupProjectError("PROJECT_API_INCOMPATIBLE");
        for (const node of data.nodes) {
            if (node === null) continue;
            if (!isRecord(node)
                || typeof node.id !== "string"
                || !isRecord(node.repository)
                || typeof node.repository.nameWithOwner !== "string"
                || typeof node.repository.isPrivate !== "boolean") {
                throw new SetupProjectError("PROJECT_API_INCOMPATIBLE");
            }
            if (node.repository.nameWithOwner === repositoryNameWithOwner
                && node.repository.isPrivate
                && issueNodeIDs.includes(node.id)) {
                return "VERIFIED";
            }
        }
        return "UNVERIFIED";
    }

    private async requestPage(
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
            throw new SetupProjectError("TRANSIENT_GITHUB_FAILURE");
        }
        if (!response.ok) {
            if (response.status === 403
                && !isRateLimited(response.headers)
                && !hasProjectScope(response.headers.get("X-OAuth-Scopes"))) {
                throw new SetupProjectError("OAUTH_SCOPE_MISSING", response.status);
            }
            throw classifyFailure(response);
        }
        if (!hasProjectScope(response.headers.get("X-OAuth-Scopes"))) {
            throw new SetupProjectError("OAUTH_SCOPE_MISSING", response.status);
        }
        let body: unknown;
        try {
            body = await response.json();
        } catch {
            throw new SetupProjectError("PROJECT_API_INCOMPATIBLE", 502);
        }
        if (!Array.isArray(body)) {
            throw new SetupProjectError("PROJECT_API_INCOMPATIBLE", 502);
        }
        return { body, nextPage: readNextPage(response.headers.get("Link")) };
    }
}

function readNextPage(header: string | null): string | null {
    if (!header) return null;
    for (const value of header.split(",")) {
        const match = value.match(/<([^>]+)>;\s*rel="next"/);
        if (!match) continue;
        const url = new URL(match[1]);
        if (url.origin !== githubAPI) throw new SetupProjectError("PROJECT_API_INCOMPATIBLE");
        return url.toString();
    }
    return null;
}

function hasProjectScope(header: string | null): boolean {
    return (header ?? "").split(",").map((value) => value.trim()).includes("project");
}

function classifyFailure(response: Response): SetupProjectError {
    if (response.status === 401) return new SetupProjectError("OAUTH_REAUTH_REQUIRED", 401);
    if (response.status === 403 && isRateLimited(response.headers)) {
        return new SetupProjectError("TRANSIENT_GITHUB_FAILURE", 403);
    }
    if (response.status === 403) return new SetupProjectError("PROJECT_WRITE_FORBIDDEN", 403);
    if (response.status === 429 || response.status >= 500) {
        return new SetupProjectError("TRANSIENT_GITHUB_FAILURE", response.status);
    }
    return new SetupProjectError("PROJECT_API_INCOMPATIBLE", response.status);
}

function isRateLimited(headers: Headers): boolean {
    return headers.has("Retry-After") || headers.get("X-RateLimit-Remaining") === "0";
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
}

function isPositiveInteger(value: unknown): value is number {
    return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}
