import { describe, expect, test } from "vitest";
import {
    GitHubGraphQLError,
    type GraphQLRequester,
} from "../src/github-graphql";
import { GraphQLStatusWriter } from "../src/graphql-status-writer";
import type { PersonalProjectConfiguration } from "../src/personal-project-gateway";

describe("GraphQLStatusWriter", () => {
    test("uses only the GraphQL identity space for a single-select mutation", async () => {
        const graphQL = new StubGraphQL({
            updateProjectV2ItemFieldValue: { projectV2Item: { id: "ITEM_NODE" } },
        });
        const writer = new GraphQLStatusWriter(graphQL);

        await writer.updateStatus("oauth-token", project, "ITEM_NODE", "OPTION_NODE");

        expect(graphQL.variables).toEqual({
            projectID: "PROJECT_NODE",
            itemID: "ITEM_NODE",
            fieldID: "FIELD_NODE",
            optionID: "OPTION_NODE",
        });
        expect(graphQL.query).toContain("updateProjectV2ItemFieldValue");
        expect(graphQL.query).toContain("singleSelectOptionId: $optionID");
    });

    test("classifies a node resolution failure for one REST re-resolution", async () => {
        const writer = new GraphQLStatusWriter(new StubGraphQL(
            new GitHubGraphQLError("NOT_FOUND")
        ));

        await expect(writer.updateStatus("oauth-token", project, "ITEM_NODE", "OPTION_NODE"))
            .rejects.toMatchObject({ code: "ITEM_NOT_FOUND" });
    });
});

const project: PersonalProjectConfiguration = {
    oauthCredentialID: "credential",
    ownerLogin: "owner",
    number: 1,
    projectNodeID: "PROJECT_NODE",
    statusFieldNodeID: "FIELD_NODE",
    statusOptionIDs: {
        IN_PROGRESS: "PROGRESS_NODE",
        IN_REVIEW: "REVIEW_NODE",
        DONE: "DONE_NODE",
    },
};

class StubGraphQL implements GraphQLRequester {
    query = "";
    variables: Record<string, unknown> = {};

    constructor(private readonly result: unknown) {}

    async request<T>(
        _token: string,
        query: string,
        variables: Record<string, unknown>
    ): Promise<T> {
        this.query = query;
        this.variables = variables;
        if (this.result instanceof Error) throw this.result;
        return this.result as T;
    }
}
