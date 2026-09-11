import { afterEach, describe, expect, test, vi } from "vitest";
import { AutomationRunner } from "../src/automation-runner";
import type { DeliveryMessage } from "../src/index";
import { PersonalProjectError, PersonalProjectGateway } from "../src/personal-project-gateway";
import type { IssueWorkflowTruth } from "../src/workflow-models";

afterEach(() => vi.unstubAllGlobals());

describe("AutomationRunner", () => {
    test.each([
        ["TRANSIENT_GITHUB_FAILURE", true],
        ["PROJECT_CONFIGURATION_INVALID", true],
        ["TRANSIENT_GITHUB_FAILURE", false],
        ["PROJECT_CONFIGURATION_INVALID", false],
    ] as const)("publishes confirmed writes before %s (across projects: %s)", async (code, acrossProjects) => {
        const database = new RunnerDatabase();
        const notifier = new StubNotifier();
        const writer = { updateStatus: vi.fn().mockResolvedValueOnce(undefined)
            .mockRejectedValueOnce(new PersonalProjectError(code)) };
        vi.stubGlobal("fetch", vi.fn().mockImplementation(async () => itemResponse(
            acrossProjects ? ["ISSUE"] : ["ISSUE", "ISSUE_2"]
        )));
        const gateway = new PersonalProjectGateway(
            { withValidAccessToken: async (_id, operation) => operation("test-token") },
            writer, projectCatalog(acrossProjects), "2026-03-10"
        );
        const runner = new AutomationRunner(
            database.binding,
            new StubTruthReader(acrossProjects ? [issueTruth()] : [issueTruth(), { ...issueTruth(), issueNodeID: "ISSUE_2" }]),
            gateway, notifier
        );

        const transient = code === "TRANSIENT_GITHUB_FAILURE";
        await expect(runner.run(message, 1)).resolves.toEqual(
            transient ? { action: "retry", delaySeconds: 60 } : { action: "ack" }
        );
        expect(writer.updateStatus).toHaveBeenCalledTimes(2);
        expect(database.deliveryState).toBe(transient ? "RETRYING" : "FAILED");
        expect(database.errorCode).toBe(code);
        expect(database.enabled).toBe(transient ? 1 : 0);
        expect(notifier.calls.map((call) => call.type)).toEqual(
            transient ? ["project_data_changed"] : ["automation_changed", "project_data_changed"]
        );
    });

    test("keeps confirmed writes when OAuth repeats the operation and the retry fails", async () => {
        const database = new RunnerDatabase();
        const notifier = new StubNotifier();
        vi.stubGlobal("fetch", vi.fn()
            .mockResolvedValueOnce(itemResponse(["ISSUE"]))
            .mockResolvedValueOnce(itemResponse(["ISSUE"]))
            .mockResolvedValueOnce(Response.json({}, { status: 503 })));
        const writer = { updateStatus: vi.fn().mockResolvedValueOnce(undefined)
            .mockRejectedValueOnce(new PersonalProjectError("OAUTH_REAUTH_REQUIRED", 401)) };
        let tokenAttempts = 0;
        const gateway = new PersonalProjectGateway({
            async withValidAccessToken(_id, operation) {
                tokenAttempts += 1;
                try { return await operation("initial-test-token"); }
                catch (error) { expect(error).toMatchObject({ status: 401 }); }
                tokenAttempts += 1;
                return operation("refreshed-test-token");
            },
        }, writer, projectCatalog(true), "2026-03-10");
        const runner = new AutomationRunner(database.binding, new StubTruthReader([issueTruth()]), gateway, notifier);

        await expect(runner.run(message, 1)).resolves.toEqual({ action: "retry", delaySeconds: 60 });
        expect(tokenAttempts).toBe(2);
        expect(writer.updateStatus).toHaveBeenCalledTimes(2);
        expect(database.deliveryState).toBe("RETRYING");
        expect(notifier.calls).toEqual([{ automationID: "automation", type: "project_data_changed" }]);
    });
    test("acks an already completed duplicate without reading GitHub again", async () => {
        const database = new RunnerDatabase({ processing_state: "COMPLETED" });
        const truthReader = new StubTruthReader([]);
        const gateway = new StubGateway({});
        const notifier = new StubNotifier();
        const runner = new AutomationRunner(database.binding, truthReader, gateway, notifier);

        await expect(runner.run(message, 2)).resolves.toEqual({ action: "ack" });
        expect(truthReader.calls).toBe(0);
        expect(gateway.calls).toBe(0);
        expect(notifier.calls).toEqual([]);
    });

    test("recomputes current truth and completes an idempotent delivery", async () => {
        const database = new RunnerDatabase();
        const truthReader = new StubTruthReader([issueTruth()]);
        const gateway = new StubGateway({ ISSUE: "APPLIED" });
        const notifier = new StubNotifier();
        const runner = new AutomationRunner(database.binding, truthReader, gateway, notifier);

        await expect(runner.run(message, 1)).resolves.toEqual({ action: "ack" });
        expect(gateway.assignments).toEqual([{
            issueNodeID: "ISSUE",
            issueRepositoryNameWithOwner: "owner/issues",
            desiredStatus: "IN_REVIEW",
        }]);
        expect(database.deliveryState).toBe("COMPLETED");
        expect(database.attemptCount).toBe(1);
        expect(database.automationHealth).toBe("ACTIVE");
        expect(notifier.calls).toEqual([{
            automationID: "automation",
            type: "project_data_changed",
        }]);
    });

    test("retries only a transient classified failure", async () => {
        const database = new RunnerDatabase();
        const gateway = new StubGateway({});
        gateway.error = new PersonalProjectError("TRANSIENT_GITHUB_FAILURE", 503);
        const runner = new AutomationRunner(
            database.binding,
            new StubTruthReader([issueTruth()]),
            gateway,
            new StubNotifier()
        );

        await expect(runner.run(message, 3)).resolves.toEqual({
            action: "retry",
            delaySeconds: 240,
        });
        expect(database.deliveryState).toBe("RETRYING");
        expect(database.errorCode).toBe("TRANSIENT_GITHUB_FAILURE");
    });

    test("publishes after a terminal OAuth failure changes connection health", async () => {
        const database = new RunnerDatabase();
        const gateway = new StubGateway({});
        gateway.error = new PersonalProjectError("OAUTH_REAUTH_REQUIRED", 401);
        const notifier = new StubNotifier();
        const runner = new AutomationRunner(
            database.binding,
            new StubTruthReader([issueTruth()]),
            gateway,
            notifier
        );

        await expect(runner.run(message, 1)).resolves.toEqual({ action: "ack" });
        expect(database.deliveryState).toBe("FAILED");
        expect(database.errorCode).toBe("OAUTH_REAUTH_REQUIRED");
        expect(notifier.calls).toEqual([{
            automationID: "automation",
            type: "automation_changed",
        }]);
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
            gateway,
            new StubNotifier()
        );

        await expect(runner.run(message, 1)).resolves.toEqual({ action: "ack" });
        expect(gateway.calls).toBe(0);
        expect(database.deliveryState).toBe("COMPLETED");
    });

    test("does not publish when GitHub reports no project change", async () => {
        const database = new RunnerDatabase();
        const notifier = new StubNotifier();
        const runner = new AutomationRunner(
            database.binding,
            new StubTruthReader([issueTruth()]),
            new StubGateway({ ISSUE: "NOT_IN_PROJECT" }),
            notifier
        );

        await expect(runner.run(message, 1)).resolves.toEqual({ action: "ack" });
        expect(notifier.calls).toEqual([]);
    });

    test("keeps a completed delivery successful when event publication fails", async () => {
        const database = new RunnerDatabase();
        const notifier = new StubNotifier();
        notifier.error = new Error("unavailable");
        const runner = new AutomationRunner(
            database.binding,
            new StubTruthReader([issueTruth()]),
            new StubGateway({ ISSUE: "APPLIED" }),
            notifier
        );

        await expect(runner.run(message, 1)).resolves.toEqual({ action: "ack" });
        expect(database.deliveryState).toBe("COMPLETED");
        expect(notifier.calls).toEqual([{
            automationID: "automation",
            type: "project_data_changed",
        }]);
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

    async applyStatuses(_project: unknown, assignments: unknown[], onApplied: () => void): Promise<Record<string, "APPLIED" | "NOT_IN_PROJECT">> {
        this.calls += 1;
        this.assignments = assignments;
        if (this.error) throw this.error;
        for (const outcome of Object.values(this.outcomes)) {
            if (outcome === "APPLIED") onApplied();
        }
        return this.outcomes;
    }
}

class StubNotifier {
    calls: Array<{ automationID: string; type: string }> = [];
    error: Error | null = null;

    async publish(automationID: string, type: string): Promise<void> {
        this.calls.push({ automationID, type });
        if (this.error) throw this.error;
    }
}

class RunnerDatabase {
    deliveryState: string;
    attemptCount = 0;
    enabled = 1;
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
            review_status_policy: "USE_CONFIGURED_OPTION",
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
                        } else if (sql.includes("SET enabled = 0")) {
                            this.enabled = 0;
                            this.automationHealth = String(values[0]);
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

function itemResponse(issueIDs: string[]): Response {
    return Response.json(issueIDs.map((id) => ({ node_id: `ITEM_${id}`, content: { node_id: id } })), {
        headers: { "X-OAuth-Scopes": "project" },
    });
}

function projectCatalog(acrossProjects: boolean) {
    return {
        async listProjects() {
            return acrossProjects
                ? [{ nodeID: "PROJECT", number: 1, title: "First" }, { nodeID: "PROJECT_2", number: 2, title: "Second" }]
                : [{ nodeID: "PROJECT", number: 1, title: "First" }];
        },
        async listStatusFields() {
            return [{ nodeID: "FIELD", name: "Status", options: [
                { id: "PROGRESS", name: "In Progress" }, { id: "REVIEW", name: "In Review" }, { id: "DONE", name: "Done" },
            ] }];
        },
        async ensureStatusOption(): Promise<{ id: string; name: string }> {
            throw new Error("Unexpected status option creation");
        },
    };
}
