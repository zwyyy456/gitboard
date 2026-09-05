import type { AccessTokenProvider } from "./oauth-credential-provider";
import {
    GitHubProjectsRESTClient,
    GitHubProjectsRESTError,
    githubProjectsURL,
} from "./github-projects-rest";
import type {
    SetupProject,
    SetupProjectClient,
    SetupStatusField,
} from "./setup-project-client";
import { SetupProjectError } from "./setup-project-client";
import type { DesiredStatus } from "./workflow-models";

export interface PersonalProjectConfiguration {
    oauthCredentialID: string;
    ownerLogin: string;
    number: number;
    projectNodeID: string;
    statusFieldNodeID: string;
    statusOptionIDs: Record<DesiredStatus, string>;
    reviewStatusPolicy: ReviewStatusPolicy;
}

export type ReviewStatusPolicy =
    | "ENSURE_IN_REVIEW"
    | "USE_IN_PROGRESS"
    | "USE_CONFIGURED_OPTION";

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
    private readonly projectsREST: GitHubProjectsRESTClient;

    constructor(
        private readonly accessTokens: AccessTokenProvider,
        private readonly statusWriter: ProjectStatusWriter,
        private readonly projectCatalog: Pick<
            SetupProjectClient,
            "listProjects" | "listStatusFields" | "ensureStatusOption"
        >,
        apiVersion: string
    ) {
        this.projectsREST = new GitHubProjectsRESTClient(apiVersion);
    }

    async applyStatuses(
        project: PersonalProjectConfiguration,
        assignments: IssueStatusAssignment[]
    ): Promise<Record<string, ApplyOutcome>> {
        return this.accessTokens.withValidAccessToken(
            project.oauthCredentialID,
            async (accessToken) => {
                try {
                    return await this.applyWithToken(accessToken, project, assignments);
                } catch (error) {
                    if (error instanceof SetupProjectError) throw mapProjectCatalogError(error);
                    throw error;
                }
            }
        );
    }

    private async applyWithToken(
        accessToken: string,
        template: PersonalProjectConfiguration,
        assignments: IssueStatusAssignment[]
    ): Promise<Record<string, ApplyOutcome>> {
        const mapping = await this.loadMapping(accessToken, template);
        const projects = await this.projectCatalog.listProjects(
            accessToken,
            template.ownerLogin
        );
        const outcomes: Record<string, ApplyOutcome> = Object.fromEntries(
            assignments.map((assignment) => [assignment.issueNodeID, "NOT_IN_PROJECT" as const])
        );

        for (const project of projects) {
            const fields = project.nodeID === template.projectNodeID
                ? mapping.templateFields
                : await this.projectCatalog.listStatusFields(
                    accessToken,
                    template.ownerLogin,
                    project.number
                );
            const resolution = projectConfiguration(
                template,
                project,
                fields,
                mapping
            );
            if (!resolution) continue;
            const projectOutcomes = await this.applyToProject(
                accessToken,
                resolution,
                assignments
            );
            for (const [issueNodeID, outcome] of Object.entries(projectOutcomes)) {
                if (outcome === "APPLIED") outcomes[issueNodeID] = "APPLIED";
            }
        }
        return outcomes;
    }

    private async loadMapping(
        accessToken: string,
        template: PersonalProjectConfiguration
    ): Promise<StatusMapping> {
        const fields = await this.projectCatalog.listStatusFields(
            accessToken,
            template.ownerLogin,
            template.number
        );
        const field = fields.find((candidate) => candidate.nodeID === template.statusFieldNodeID);
        const inProgress = field?.options.find(
            (option) => option.id === template.statusOptionIDs.IN_PROGRESS
        );
        const configuredReview = field?.options.find(
            (option) => option.id === template.statusOptionIDs.IN_REVIEW
        );
        const done = field?.options.find(
            (option) => option.id === template.statusOptionIDs.DONE
        );
        if (!field
            || !inProgress
            || !done
            || (template.reviewStatusPolicy === "USE_CONFIGURED_OPTION" && !configuredReview)) {
            throw new PersonalProjectError("PROJECT_CONFIGURATION_INVALID");
        }
        return {
            fieldName: field.name,
            optionNames: {
                IN_PROGRESS: inProgress.name,
                IN_REVIEW: template.reviewStatusPolicy === "USE_CONFIGURED_OPTION"
                    ? configuredReview!.name
                    : "In review",
                DONE: done.name,
            },
            templateFields: fields,
        };
    }

    private async applyToProject(
        accessToken: string,
        resolution: ProjectConfigurationResolution,
        assignments: IssueStatusAssignment[]
    ): Promise<Record<string, ApplyOutcome>> {
        let project = resolution.configuration;
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

        const needsReviewOption = resolution.shouldEnsureInReview
            && assignments.some((assignment) => (
                assignment.desiredStatus === "IN_REVIEW"
                && resolvedItems.has(assignment.issueNodeID)
            ));
        if (needsReviewOption) {
            const inReview = await this.projectCatalog.ensureStatusOption(
                accessToken,
                project.statusFieldNodeID,
                "In review"
            );
            project = {
                ...project,
                statusOptionIDs: {
                    ...project.statusOptionIDs,
                    IN_REVIEW: inReview.id,
                },
            };
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
        try {
            const page = await this.projectsREST.requestPage(url, accessToken);
            const items = page.body.map((value) => {
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
            return { items, nextPage: page.nextPage };
        } catch (error) {
            if (error instanceof GitHubProjectsRESTError) {
                throw mapRESTError(error);
            }
            throw error;
        }
    }
}

interface StatusMapping {
    fieldName: string;
    optionNames: Record<DesiredStatus, string>;
    templateFields: SetupStatusField[];
}

interface ProjectConfigurationResolution {
    configuration: PersonalProjectConfiguration;
    shouldEnsureInReview: boolean;
}

function projectConfiguration(
    template: PersonalProjectConfiguration,
    project: SetupProject,
    fields: SetupStatusField[],
    mapping: StatusMapping
): ProjectConfigurationResolution | null {
    const field = fields.find((candidate) => candidate.name === mapping.fieldName);
    if (!field) return null;
    const inProgress = findStatusOption(field.options, mapping.optionNames.IN_PROGRESS);
    const done = findStatusOption(field.options, mapping.optionNames.DONE);
    if (!inProgress || !done) return null;
    const existingInReview = findStatusOption(field.options, mapping.optionNames.IN_REVIEW);
    const inReview = template.reviewStatusPolicy === "USE_IN_PROGRESS"
        ? inProgress
        : existingInReview ?? inProgress;
    return {
        configuration: {
            oauthCredentialID: template.oauthCredentialID,
            ownerLogin: template.ownerLogin,
            number: project.number,
            projectNodeID: project.nodeID,
            statusFieldNodeID: field.nodeID,
            statusOptionIDs: {
                IN_PROGRESS: inProgress.id,
                IN_REVIEW: inReview.id,
                DONE: done.id,
            },
            reviewStatusPolicy: template.reviewStatusPolicy,
        },
        shouldEnsureInReview: template.reviewStatusPolicy === "ENSURE_IN_REVIEW"
            && existingInReview === undefined,
    };
}

function findStatusOption<T extends { name: string }>(
    options: T[],
    name: string
): T | undefined {
    return options.find((option) => option.name === name)
        ?? options.find((option) => option.name.toLowerCase() === name.toLowerCase());
}

function projectItemsURL(
    project: PersonalProjectConfiguration,
    issueRepositoryNameWithOwner: string
): string {
    const url = githubProjectsURL(
        `/users/${encodeURIComponent(project.ownerLogin)}/projectsV2/${project.number}/items`
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

function mapRESTError(error: GitHubProjectsRESTError): PersonalProjectError {
    switch (error.code) {
    case "AUTH_REQUIRED":
        return new PersonalProjectError("OAUTH_REAUTH_REQUIRED", error.status);
    case "SCOPE_MISSING":
        return new PersonalProjectError("OAUTH_SCOPE_MISSING", error.status);
    case "FORBIDDEN":
    case "NOT_FOUND":
        return new PersonalProjectError("PROJECT_CONFIGURATION_INVALID", error.status);
    case "TRANSIENT":
        return new PersonalProjectError("TRANSIENT_GITHUB_FAILURE", error.status);
    case "INCOMPATIBLE":
        return new PersonalProjectError("PROJECT_API_INCOMPATIBLE", error.status);
    }
}

function mapProjectCatalogError(error: SetupProjectError): PersonalProjectError {
    switch (error.code) {
    case "OAUTH_REAUTH_REQUIRED":
        return new PersonalProjectError("OAUTH_REAUTH_REQUIRED", error.status);
    case "OAUTH_SCOPE_MISSING":
        return new PersonalProjectError("OAUTH_SCOPE_MISSING", error.status);
    case "PROJECT_API_INCOMPATIBLE":
        return new PersonalProjectError("PROJECT_API_INCOMPATIBLE", error.status);
    case "PROJECT_WRITE_FORBIDDEN":
        return new PersonalProjectError("PROJECT_CONFIGURATION_INVALID", error.status);
    case "TRANSIENT_GITHUB_FAILURE":
        return new PersonalProjectError("TRANSIENT_GITHUB_FAILURE", error.status);
    }
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
}
