import {
    GitHubGraphQLError,
    type GraphQLRequester,
} from "./github-graphql";
import {
    PersonalProjectError,
    type PersonalProjectConfiguration,
    type ProjectStatusWriter,
    ProjectStatusWriterError,
} from "./personal-project-gateway";

export class GraphQLStatusWriter implements ProjectStatusWriter {
    constructor(private readonly graphQL: GraphQLRequester) {}

    async updateStatus(
        accessToken: string,
        project: PersonalProjectConfiguration,
        itemNodeID: string,
        statusOptionID: string
    ): Promise<void> {
        let data: unknown;
        try {
            data = await this.graphQL.request(
                accessToken,
                updateStatusMutation,
                {
                    projectID: project.projectNodeID,
                    itemID: itemNodeID,
                    fieldID: project.statusFieldNodeID,
                    optionID: statusOptionID,
                }
            );
        } catch (error) {
            if (error instanceof GitHubGraphQLError) {
                throw mapGraphQLError(error);
            }
            throw error;
        }
        if (!isRecord(data)
            || !isRecord(data.updateProjectV2ItemFieldValue)
            || !isRecord(data.updateProjectV2ItemFieldValue.projectV2Item)
            || data.updateProjectV2ItemFieldValue.projectV2Item.id !== itemNodeID) {
            throw new PersonalProjectError("PROJECT_CONFIGURATION_INVALID");
        }
    }
}

const updateStatusMutation = `
mutation UpdateProjectItemStatus(
  $projectID: ID!
  $itemID: ID!
  $fieldID: ID!
  $optionID: String!
) {
  updateProjectV2ItemFieldValue(input: {
    projectId: $projectID
    itemId: $itemID
    fieldId: $fieldID
    value: { singleSelectOptionId: $optionID }
  }) {
    projectV2Item { id }
  }
}`;

function mapGraphQLError(error: GitHubGraphQLError): Error {
    switch (error.kind) {
    case "AUTHENTICATION":
        return new PersonalProjectError("OAUTH_REAUTH_REQUIRED", 401);
    case "FORBIDDEN":
        return new PersonalProjectError("OAUTH_REAUTH_REQUIRED", 403);
    case "NOT_FOUND":
        return new ProjectStatusWriterError("ITEM_NOT_FOUND");
    case "TRANSIENT":
        return new PersonalProjectError("TRANSIENT_GITHUB_FAILURE", error.status);
    case "INVALID_RESPONSE":
        return new PersonalProjectError("PROJECT_CONFIGURATION_INVALID", error.status);
    }
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
}
