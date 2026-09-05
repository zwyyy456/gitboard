import {
    GitHubGraphQLError,
    type GraphQLRequester,
} from "./github-graphql";
import {
    GitHubProjectsRESTClient,
    GitHubProjectsRESTError,
    githubProjectsURL,
} from "./github-projects-rest";

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

interface StatusOptionDetails {
    id: string;
    name: string;
    color: string;
    description: string;
}

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
    private readonly projectsREST: GitHubProjectsRESTClient;

    constructor(
        private readonly graphQL: GraphQLRequester,
        apiVersion: string
    ) {
        this.projectsREST = new GitHubProjectsRESTClient(apiVersion);
    }

    async listProjects(accessToken: string, ownerLogin: string): Promise<SetupProject[]> {
        const projects: SetupProject[] = [];
        let url: string | null = githubProjectsURL(
            `/users/${encodeURIComponent(ownerLogin)}/projectsV2?per_page=100`
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
        let url: string | null = githubProjectsURL(
            `/users/${encodeURIComponent(ownerLogin)}/projectsV2/${projectNumber}/fields?per_page=100`
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

    async ensureStatusOption(
        accessToken: string,
        fieldNodeID: string,
        optionName: string
    ): Promise<{ id: string; name: string }> {
        try {
            const options = await this.loadStatusOptionDetails(accessToken, fieldNodeID);
            const existing = findStatusOption(options, optionName);
            if (existing) return { id: existing.id, name: existing.name };

            const optionInputs: Array<{
                id?: string;
                name: string;
                color: string;
                description: string;
            }> = options.map((option) => ({
                id: option.id,
                name: option.name,
                color: option.color,
                description: option.description,
            }));
            optionInputs.push({
                name: optionName,
                color: "ORANGE",
                description: "",
            });
            const data = await this.graphQL.request<{
                updateProjectV2Field: null | {
                    projectV2Field: null | {
                        id: string;
                        options: unknown[];
                    };
                };
            }>(accessToken, updateStatusFieldMutation, {
                fieldID: fieldNodeID,
                options: optionInputs,
            });
            const field = data.updateProjectV2Field?.projectV2Field;
            if (!field || field.id !== fieldNodeID) {
                throw new SetupProjectError("PROJECT_API_INCOMPATIBLE");
            }
            const updated = findStatusOption(parseStatusOptions(field.options), optionName);
            if (!updated) throw new SetupProjectError("PROJECT_API_INCOMPATIBLE");
            return { id: updated.id, name: updated.name };
        } catch (error) {
            if (error instanceof GitHubGraphQLError) throw mapGraphQLError(error);
            throw error;
        }
    }

    private async loadStatusOptionDetails(
        accessToken: string,
        fieldNodeID: string
    ): Promise<StatusOptionDetails[]> {
        const data = await this.graphQL.request<{
            node: null | { id: string; options: unknown[] };
        }>(accessToken, statusFieldOptionsQuery, { fieldID: fieldNodeID });
        if (!data.node || data.node.id !== fieldNodeID) {
            throw new SetupProjectError("PROJECT_API_INCOMPATIBLE");
        }
        return parseStatusOptions(data.node.options);
    }

    private async requestPage(
        url: string,
        accessToken: string
    ): Promise<{ body: unknown[]; nextPage: string | null }> {
        try {
            return await this.projectsREST.requestPage(url, accessToken);
        } catch (error) {
            if (error instanceof GitHubProjectsRESTError) {
                throw mapRESTError(error);
            }
            throw error;
        }
    }
}

const statusFieldOptionsQuery = `
query SetupStatusFieldOptions($fieldID: ID!) {
  node(id: $fieldID) {
    ... on ProjectV2SingleSelectField {
      id
      options { id name color description }
    }
  }
}`;

const updateStatusFieldMutation = `
mutation EnsureSetupStatusOption(
  $fieldID: ID!
  $options: [ProjectV2SingleSelectFieldOptionInput!]!
) {
  updateProjectV2Field(input: {
    fieldId: $fieldID
    singleSelectOptions: $options
  }) {
    projectV2Field {
      ... on ProjectV2SingleSelectField {
        id
        options { id name color description }
      }
    }
  }
}`;

function parseStatusOptions(values: unknown[]): StatusOptionDetails[] {
    return values.map((value) => {
        if (!isRecord(value)
            || typeof value.id !== "string"
            || typeof value.name !== "string"
            || typeof value.color !== "string"
            || typeof value.description !== "string") {
            throw new SetupProjectError("PROJECT_API_INCOMPATIBLE");
        }
        return {
            id: value.id,
            name: value.name,
            color: value.color,
            description: value.description,
        };
    });
}

function findStatusOption<T extends { name: string }>(
    options: T[],
    name: string
): T | undefined {
    return options.find((option) => option.name === name)
        ?? options.find((option) => option.name.toLowerCase() === name.toLowerCase());
}

function mapRESTError(error: GitHubProjectsRESTError): SetupProjectError {
    switch (error.code) {
    case "AUTH_REQUIRED":
        return new SetupProjectError("OAUTH_REAUTH_REQUIRED", error.status);
    case "SCOPE_MISSING":
        return new SetupProjectError("OAUTH_SCOPE_MISSING", error.status);
    case "FORBIDDEN":
        return new SetupProjectError("PROJECT_WRITE_FORBIDDEN", error.status);
    case "TRANSIENT":
        return new SetupProjectError("TRANSIENT_GITHUB_FAILURE", error.status);
    case "NOT_FOUND":
    case "INCOMPATIBLE":
        return new SetupProjectError("PROJECT_API_INCOMPATIBLE", error.status);
    }
}

function mapGraphQLError(error: GitHubGraphQLError): SetupProjectError {
    switch (error.kind) {
    case "AUTHENTICATION":
        return new SetupProjectError("OAUTH_REAUTH_REQUIRED", error.status);
    case "FORBIDDEN":
        return new SetupProjectError("PROJECT_WRITE_FORBIDDEN", error.status);
    case "TRANSIENT":
        return new SetupProjectError("TRANSIENT_GITHUB_FAILURE", error.status);
    case "NOT_FOUND":
    case "INVALID_RESPONSE":
        return new SetupProjectError("PROJECT_API_INCOMPATIBLE", error.status);
    }
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
}

function isPositiveInteger(value: unknown): value is number {
    return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}
