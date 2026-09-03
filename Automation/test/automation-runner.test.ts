import { describe, expect, test } from "vitest";
import { AutomationRunner } from "../src/automation-runner";
import type { DeliveryMessage } from "../src/index";
import { PersonalProjectError } from "../src/personal-project-gateway";
import type { IssueWorkflowTruth } from "../src/workflow-models";

describe("AutomationRunner", () => {
    test("acks an already completed duplicate without reading GitHub again", async () => {
        const database = new RunnerDatabase({ processing_state: "COMPLETED" });
        const truthReader = new StubTruthReader([]);
        const gateway = new StubGateway({});
        const runner = new AutomationRunner(database.binding, truthReader, gateway);

        await expect(runner.run(message, 2)).resolves.toEqual({ action: "ack" });
        expect(truthReader.calls).toBe(0);
        expect(gateway.calls).toBe(0);
    });

    test("recomputes current truth and completes an idempotent delivery", async () => {
        const database = new RunnerDatabase();
        const truthReader = new StubTruthReader([issueTruth()]);
        const gateway = new StubGateway({ ISSUE: "APPLIED" });
        const runner = new AutomationRunner(database.binding, truthReader, gateway);

        await expect(runner.run(message, 1)).resolves.toEqual({ action: "ack" });
        expect(gateway.assignments).toEqual([{
            issueNodeID: "ISSUE",
            issueRepositoryNameWithOwner: "owner/issues",
            desiredStatus: "IN_REVIEW",
        }]);
        expect(database.deliveryState).toBe("COMPLETED");
        expect(database.attemptCount).toBe(1);
        expect(database.automationHealth).toBe("ACTIVE");
    });

    test("retries only a transient classified failure", async () => {
        const database = new RunnerDatabase();
        const gateway = new StubGateway({});
        gateway.error = new PersonalProjectError("TRANSIENT_GITHUB_FAILURE", 503);
        const runner = new AutomationRunner(
            database.binding,
            new StubTruthReader([issueTruth()]),
            gateway
        );

        await expect(runner.run(message, 3)).resolves.toEqual({
            action: "retry",
            delaySeconds: 240,
        });
        expect(database.deliveryState).toBe("RETRYING");
        expect(database.errorCode).toBe("TRANSIENT_GITHUB_FAILURE");
    });

    test("does not open OAuth when current truth has no desired status", async () => {
        const database = new RunnerDatabase();
        const gateway = new StubGateway({});
        const runner = new AutomationRunner(
            database.binding,
            new StubTruthReader([{
                ...issueTruth(),
                closingPullRequests: [],
            }]),
            gateway
        );

        await expect(runner.run(message, 1)).resolves.toEqual({ action: "ack" });
        expect(gateway.calls).toBe(0);
        expect(database.deliveryState).toBe("COMPLETED");
    });
});

const message: DeliveryMessage = {
    deliveryID: "delivery",
};

class StubTruthReader {
    calls = 0;

    constructor(private readonly truths: IssueWorkflowTruth[]) {}

    async loadWorkflowTruth(): Promise<IssueWorkflowTruth[]> {
        this.calls += 1;
        return this.truths;
    }
}

class StubGateway {
    calls = 0;
    assignments: unknown[] = [];
    error: Error | null = null;

    constructor(private readonly outcomes: Record<string, "APPLIED" | "NOT_IN_PROJECT">) {}

    async applyStatuses(_project: unknown, assignments: unknown[]): Promise<Record<string, "APPLIED" | "NOT_IN_PROJECT">> {
        this.calls += 1;
        this.assignments = assignments;
        if (this.error) throw this.error;
        return this.outcomes;
    }
}

class RunnerDatabase {
    deliveryState: string;
    attemptCount = 0;
    errorCode: string | null = null;
    automationHealth: string | null = null;

    readonly binding: D1Database;

    constructor(overrides: Record<string, unknown> = {}) {
        const automation = {
            processing_state: "QUEUED",
            automation_id: "automation",
            oauth_credential_id: "credential",
            installation_id: 7,
            installation_status: "ACTIVE",
            repository_node_id: "SOURCE_REPOSITORY",
            pull_request_number: 42,
            project_owner_login: "owner",
            project_number: 1,
            project_node_id: "PROJECT",
            status_field_node_id: "FIELD",
            in_progress_option_id: "PROGRESS",
            in_review_option_id: "REVIEW",
            done_option_id: "DONE",
            enabled: 1,
            ...overrides,
        };
        this.deliveryState = String(automation.processing_state);
        this.binding = {
            prepare: (sql: string) => {
                let values: unknown[] = [];
                const statement = {
                    bind: (...arguments_: unknown[]) => {
                        values = arguments_;
                        return statement;
                    },
                    first: async () => automation,
                    all: async () => ({ results: [
                        { repository_node_id: "SOURCE_REPOSITORY" },
                        { repository_node_id: "ISSUE_REPOSITORY" },
                    ] }),
                    run: async () => {
                        if (sql.includes("processing_state = 'PROCESSING'")) {
                            this.deliveryState = "PROCESSING";
                            this.attemptCount += 1;
                        } else if (sql.includes("processing_state = 'RETRYING'")) {
                            this.deliveryState = "RETRYING";
                            this.errorCode = String(values[0]);
                        } else if (sql.includes("SET processing_state = ?")) {
                            this.deliveryState = String(values[0]);
                            this.errorCode = values[1] == null ? null : String(values[1]);
                        } else if (sql.includes("health_state = 'ACTIVE'")) {
                            this.automationHealth = "ACTIVE";
                        }
                        return { meta: { changes: 1 } };
                    },
                };
                return statement;
            },
        } as unknown as D1Database;
    }
}

function issueTruth(): IssueWorkflowTruth {
    return {
        issueNodeID: "ISSUE",
        issueState: "OPEN",
        issueRepositoryNameWithOwner: "owner/issues",
        closingPullRequests: [{ state: "OPEN", isDraft: false }],
    };
}
