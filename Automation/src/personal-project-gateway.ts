import type { AccessTokenProvider } from "./oauth-credential-provider";
import type { DesiredStatus } from "./workflow-models";

const githubAPI = "https://api.github.com";

export interface PersonalProjectConfiguration {
    oauthCredentialID: string;
    ownerLogin: string;
    number: number;
    projectNodeID: string;
    statusFieldNodeID: string;
    statusOptionIDs: Record<DesiredStatus, string>;
}

export interface IssueStatusAssignment {
    issueNodeID: string;
    issueRepositoryNameWithOwner: string;
    desiredStatus: DesiredStatus;
}

export type ApplyOutcome = "APPLIED" | "NOT_IN_PROJECT";

export type PersonalProjectErrorCode =
    | "VISIBILITY_INDETERMINATE"
    | "PROJECT_API_INCOMPATIBLE"
    | "OAUTH_REAUTH_REQUIRED"
    | "OAUTH_SCOPE_MISSING"
    | "PROJECT_CONFIGURATION_INVALID"
    | "TRANSIENT_GITHUB_FAILURE";

export class PersonalProjectError extends Error {
    constructor(
        readonly code: PersonalProjectErrorCode,
        readonly status?: number
    ) {
        super(code);
    }
}

export interface ProjectStatusWriter {
    updateStatus(
        accessToken: string,
        project: PersonalProjectConfiguration,
        itemNodeID: string,
        statusOptionID: string
    ): Promise<void>;
}

export class ProjectStatusWriterError extends Error {
    constructor(readonly code: "ITEM_NOT_FOUND") {
        super(code);
    }
}

interface ResolvedItem {
    issueNodeID: string;
    itemNodeID: string;
}

export class PersonalProjectGateway {
    constructor(
        private readonly accessTokens: AccessTokenProvider,
        private readonly statusWriter: ProjectStatusWriter,
        private readonly apiVersion: string
    ) {}

    async applyStatuses(
        project: PersonalProjectConfiguration,
        assignments: IssueStatusAssignment[]
    ): Promise<Record<string, ApplyOutcome>> {
        return this.accessTokens.withValidAccessToken(
            project.oauthCredentialID,
            async (accessToken) => this.applyWithToken(accessToken, project, assignments)
        );
    }

    private async applyWithToken(
        accessToken: string,
        project: PersonalProjectConfiguration,
        assignments: IssueStatusAssignment[]
    ): Promise<Record<string, ApplyOutcome>> {
        const resolvedItems = new Map<string, string>();
        const missingItems = new Set<string>();

        for (const [repository, group] of groupByRepository(assignments)) {
            const resolution = await this.resolveRepositoryItems(
                accessToken,
                project,
                repository,
                group.map((assignment) => assignment.issueNodeID)
            );
            for (const item of resolution.found) {
                resolvedItems.set(item.issueNodeID, item.itemNodeID);
            }
            for (const issueNodeID of resolution.missing) {
                missingItems.add(issueNodeID);
            }
        }

        const outcomes: Record<string, ApplyOutcome> = {};
        for (const assignment of assignments) {
            const itemNodeID = resolvedItems.get(assignment.issueNodeID);
            if (!itemNodeID) {
                if (missingItems.has(assignment.issueNodeID)) {
                    outcomes[assignment.issueNodeID] = "NOT_IN_PROJECT";
                }
                continue;
            }
            outcomes[assignment.issueNodeID] = await this.writeAssignment(
                accessToken,
                project,
                assignment,
                itemNodeID
            );
        }
        return outcomes;
    }

    private async writeAssignment(
        accessToken: string,
        project: PersonalProjectConfiguration,
        assignment: IssueStatusAssignment,
        itemNodeID: string
    ): Promise<ApplyOutcome> {
        const statusOptionID = project.statusOptionIDs[assignment.desiredStatus];
        try {
            await this.statusWriter.updateStatus(
                accessToken,
                project,
                itemNodeID,
                statusOptionID
            );
            return "APPLIED";
        } catch (error) {
            if (!(error instanceof ProjectStatusWriterError)) {
                throw error;
            }
        }

        const resolution = await this.resolveRepositoryItems(
            accessToken,
            project,
            assignment.issueRepositoryNameWithOwner,
            [assignment.issueNodeID]
        );
        const replacement = resolution.found[0];
        if (!replacement) {
            return "NOT_IN_PROJECT";
        }
        try {
            await this.statusWriter.updateStatus(
                accessToken,
                project,
                replacement.itemNodeID,
                statusOptionID
            );
            return "APPLIED";
        } catch (error) {
            if (error instanceof ProjectStatusWriterError) {
                throw new PersonalProjectError("PROJECT_CONFIGURATION_INVALID");
            }
            throw error;
        }
    }

    private async resolveRepositoryItems(
        accessToken: string,
        project: PersonalProjectConfiguration,
        issueRepositoryNameWithOwner: string,
        issueNodeIDs: string[]
    ): Promise<{ found: ResolvedItem[]; missing: string[] }> {
        const unresolved = new Set(issueNodeIDs);
        const found: ResolvedItem[] = [];
        let opaqueCandidate = false;
        let url: string | null = projectItemsURL(project, issueRepositoryNameWithOwner);

        while (url && unresolved.size > 0) {
            const response = await this.requestPage(url, accessToken);
            for (const item of response.items) {
                if (!item.itemNodeID || !item.contentNodeID) {
                    opaqueCandidate = true;
                    continue;
                }
                if (unresolved.delete(item.contentNodeID)) {
                    found.push({
                        issueNodeID: item.contentNodeID,
                        itemNodeID: item.itemNodeID,
                    });
                }
            }
            url = response.nextPage;
        }

        if (unresolved.size > 0 && opaqueCandidate) {
            throw new PersonalProjectError("VISIBILITY_INDETERMINATE");
        }
        return { found, missing: [...unresolved] };
    }

    private async requestPage(
        url: string,
        accessToken: string
    ): Promise<{
        items: Array<{ itemNodeID: string | null; contentNodeID: string | null }>;
        nextPage: string | null;
    }> {
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
            throw new PersonalProjectError("TRANSIENT_GITHUB_FAILURE");
        }
        if (!response.ok) {
            if (response.status === 403
                && !isRateLimited(response.headers)
                && !hasProjectScope(response.headers.get("X-OAuth-Scopes"))) {
                throw new PersonalProjectError("OAUTH_SCOPE_MISSING", response.status);
            }
            throw classifyRESTFailure(response);
        }
        if (!hasProjectScope(response.headers.get("X-OAuth-Scopes"))) {
            throw new PersonalProjectError("OAUTH_SCOPE_MISSING", response.status);
        }

        let body: unknown;
        try {
            body = await response.json();
        } catch {
            throw new PersonalProjectError("PROJECT_API_INCOMPATIBLE", 502);
        }
        if (!Array.isArray(body)) {
            throw new PersonalProjectError("PROJECT_API_INCOMPATIBLE", 502);
        }
        const items = body.map((value) => {
            if (!isRecord(value)) {
                throw new PersonalProjectError("PROJECT_API_INCOMPATIBLE", 502);
            }
            return {
                itemNodeID: typeof value.node_id === "string" ? value.node_id : null,
                contentNodeID: isRecord(value.content) && typeof value.content.node_id === "string"
                    ? value.content.node_id
                    : null,
            };
        });
        return { items, nextPage: readNextPage(response.headers.get("Link")) };
    }
}

function projectItemsURL(
    project: PersonalProjectConfiguration,
    issueRepositoryNameWithOwner: string
): string {
    const url = new URL(
        `/users/${encodeURIComponent(project.ownerLogin)}/projectsV2/${project.number}/items`,
        githubAPI
    );
    url.searchParams.set("q", `repo:${issueRepositoryNameWithOwner} is:issue`);
    url.searchParams.set("per_page", "100");
    return url.toString();
}

function groupByRepository(
    assignments: IssueStatusAssignment[]
): Map<string, IssueStatusAssignment[]> {
    const groups = new Map<string, IssueStatusAssignment[]>();
    for (const assignment of assignments) {
        const group = groups.get(assignment.issueRepositoryNameWithOwner) ?? [];
        group.push(assignment);
        groups.set(assignment.issueRepositoryNameWithOwner, group);
    }
    return groups;
}

function readNextPage(linkHeader: string | null): string | null {
    if (!linkHeader) return null;
    for (const value of linkHeader.split(",")) {
        const match = value.match(/<([^>]+)>;\s*rel="next"/);
        if (!match) {
            if (value.includes("rel=\"next\"")) {
                throw new PersonalProjectError("PROJECT_API_INCOMPATIBLE", 502);
            }
            continue;
        }
        let url: URL;
        try {
            url = new URL(match[1]);
        } catch {
            throw new PersonalProjectError("PROJECT_API_INCOMPATIBLE", 502);
        }
        if (url.origin !== githubAPI) {
            throw new PersonalProjectError("PROJECT_API_INCOMPATIBLE", 502);
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

function classifyRESTFailure(response: Response): PersonalProjectError {
    const status = response.status;
    if (status === 401) return new PersonalProjectError("OAUTH_REAUTH_REQUIRED", status);
    if (status === 403 && isRateLimited(response.headers)) {
        return new PersonalProjectError("TRANSIENT_GITHUB_FAILURE", status);
    }
    if (status === 403) return new PersonalProjectError("PROJECT_CONFIGURATION_INVALID", status);
    if (status === 404) return new PersonalProjectError("PROJECT_CONFIGURATION_INVALID", status);
    if (status === 429 || status >= 500) {
        return new PersonalProjectError("TRANSIENT_GITHUB_FAILURE", status);
    }
    return new PersonalProjectError("PROJECT_API_INCOMPATIBLE", status);
}

function isRateLimited(headers: Headers): boolean {
    return headers.has("Retry-After") || headers.get("X-RateLimit-Remaining") === "0";
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
}
