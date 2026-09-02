import type { AutomationMessage } from "./index";
import type { OAuthCredentialError } from "./oauth-credential-provider";
import type {
    IssueStatusAssignment,
    PersonalProjectConfiguration,
    PersonalProjectError,
} from "./personal-project-gateway";
import type { RepositoryTruthError } from "./repository-truth-reader";
import type {
    InstallationContext,
    IssueWorkflowTruth,
    SourcePullRequest,
} from "./workflow-models";
import { WorkflowReducer } from "./workflow-reducer";

export type AutomationErrorCode =
    | "NOT_IN_PROJECT"
    | "VISIBILITY_INDETERMINATE"
    | "PROJECT_API_INCOMPATIBLE"
    | "ISSUE_REPOSITORY_NOT_ACCESSIBLE"
    | "OAUTH_REAUTH_REQUIRED"
    | "OAUTH_SCOPE_MISSING"
    | "PROJECT_CONFIGURATION_INVALID"
    | "TRANSIENT_GITHUB_FAILURE";

export type RunnerDecision =
    | { action: "ack" }
    | { action: "retry"; delaySeconds: number };

interface WorkflowTruthLoader {
    loadWorkflowTruth(
        installation: InstallationContext,
        sourcePullRequest: SourcePullRequest
    ): Promise<IssueWorkflowTruth[]>;
}

interface StatusGateway {
    applyStatuses(
        project: PersonalProjectConfiguration,
        assignments: IssueStatusAssignment[]
    ): Promise<Record<string, "APPLIED" | "NOT_IN_PROJECT">>;
}

interface AutomationRecord {
    processing_state: string;
    automation_id: string;
    oauth_credential_id: string;
    installation_id: number;
    installation_status: string;
    repository_name_with_owner: string;
    project_owner_login: string;
    project_number: number;
    project_node_id: string;
    status_field_node_id: string;
    in_progress_option_id: string;
    in_review_option_id: string;
    done_option_id: string;
    enabled: number;
}

interface RepositoryRecord {
    repository_id: number;
}

const terminalDeliveryStates = new Set(["COMPLETED", "FAILED", "IGNORED"]);

export class AutomationRunner {
    constructor(
        private readonly database: D1Database,
        private readonly truthReader: WorkflowTruthLoader,
        private readonly projectGateway: StatusGateway
    ) {}

    async run(message: AutomationMessage, attempt: number): Promise<RunnerDecision> {
        const automation = await this.loadAutomation(message);
        if (!automation || terminalDeliveryStates.has(automation.processing_state)) {
            return { action: "ack" };
        }
        if (automation.enabled !== 1 || automation.installation_status !== "ACTIVE") {
            await this.finishDelivery(message.deliveryID, "IGNORED", null);
            return { action: "ack" };
        }

        await this.database.prepare(
            `UPDATE webhook_deliveries
             SET processing_state = 'PROCESSING', attempt_count = attempt_count + 1
             WHERE delivery_id = ?`
        ).bind(message.deliveryID).run();

        try {
            const repositoryIDs = await this.loadInstallationRepositoryIDs(automation.installation_id);
            const truths = await this.truthReader.loadWorkflowTruth(
                { id: automation.installation_id, repositoryIDs },
                {
                    repositoryNameWithOwner: automation.repository_name_with_owner,
                    number: message.pullRequestNumber,
                }
            );
            const assignments = truths.flatMap<IssueStatusAssignment>((truth) => {
                const desiredStatus = WorkflowReducer.reduce(truth);
                return desiredStatus ? [{
                    issueNodeID: truth.issueNodeID,
                    issueRepositoryNameWithOwner: truth.issueRepositoryNameWithOwner,
                    desiredStatus,
                }] : [];
            });
            const outcomes = assignments.length > 0
                ? await this.projectGateway.applyStatuses(configuration(automation), assignments)
                : {};
            const hasMissingItem = Object.values(outcomes).includes("NOT_IN_PROJECT");
            await this.finishDelivery(
                message.deliveryID,
                "COMPLETED",
                hasMissingItem ? "NOT_IN_PROJECT" : null
            );
            return { action: "ack" };
        } catch (error) {
            return this.handleFailure(message.deliveryID, automation, error, attempt);
        }
    }

    private async loadAutomation(message: AutomationMessage): Promise<AutomationRecord | null> {
        return this.database.prepare(
            `SELECT delivery.processing_state,
                    automation.id AS automation_id,
                    automation.oauth_credential_id,
                    automation.installation_id,
                    installation.status AS installation_status,
                    automation.repository_name_with_owner,
                    automation.project_owner_login,
                    automation.project_number,
                    automation.project_node_id,
                    automation.status_field_node_id,
                    automation.in_progress_option_id,
                    automation.in_review_option_id,
                    automation.done_option_id,
                    automation.enabled
             FROM webhook_deliveries delivery
             JOIN project_automations automation ON automation.id = delivery.automation_id
             JOIN installations installation
               ON installation.installation_id = automation.installation_id
             WHERE delivery.delivery_id = ?
               AND automation.installation_id = ?
               AND automation.repository_id = ?`
        ).bind(
            message.deliveryID,
            message.installationID,
            message.repositoryID
        ).first<AutomationRecord>();
    }

    private async loadInstallationRepositoryIDs(installationID: number): Promise<Set<number>> {
        const result = await this.database.prepare(
            "SELECT repository_id FROM installation_repositories WHERE installation_id = ?"
        ).bind(installationID).all<RepositoryRecord>();
        return new Set(result.results.map((repository) => repository.repository_id));
    }

    private async handleFailure(
        deliveryID: string,
        automation: AutomationRecord,
        error: unknown,
        attempt: number
    ): Promise<RunnerDecision> {
        const code = classifyError(error);
        if (code === "TRANSIENT_GITHUB_FAILURE") {
            await this.database.prepare(
                `UPDATE webhook_deliveries
                 SET processing_state = 'RETRYING', error_code = ?
                 WHERE delivery_id = ?`
            ).bind(code, deliveryID).run();
            return { action: "retry", delaySeconds: retryDelay(attempt) };
        }

        await this.finishDelivery(deliveryID, "FAILED", code);
        await this.database.prepare(
            `UPDATE project_automations
             SET enabled = 0, health_state = ?, updated_at = ?
             WHERE id = ?`
        ).bind(code, new Date().toISOString(), automation.automation_id).run();
        if (code === "OAUTH_REAUTH_REQUIRED" || code === "OAUTH_SCOPE_MISSING") {
            await this.database.prepare(
                `UPDATE oauth_credentials
                 SET health_state = ?, updated_at = ?
                 WHERE id = ? AND health_state != 'REVOKED'`
            ).bind(
                code === "OAUTH_SCOPE_MISSING" ? "SCOPE_MISSING" : "REAUTHORIZATION_REQUIRED",
                new Date().toISOString(),
                automation.oauth_credential_id
            ).run();
        }
        return { action: "ack" };
    }

    private async finishDelivery(
        deliveryID: string,
        state: "COMPLETED" | "FAILED" | "IGNORED",
        errorCode: AutomationErrorCode | null
    ): Promise<void> {
        await this.database.prepare(
            `UPDATE webhook_deliveries
             SET processing_state = ?, error_code = ?, completed_at = ?
             WHERE delivery_id = ?`
        ).bind(state, errorCode, new Date().toISOString(), deliveryID).run();
    }
}

function configuration(automation: AutomationRecord): PersonalProjectConfiguration {
    return {
        oauthCredentialID: automation.oauth_credential_id,
        ownerLogin: automation.project_owner_login,
        number: automation.project_number,
        projectNodeID: automation.project_node_id,
        statusFieldNodeID: automation.status_field_node_id,
        statusOptionIDs: {
            IN_PROGRESS: automation.in_progress_option_id,
            IN_REVIEW: automation.in_review_option_id,
            DONE: automation.done_option_id,
        },
    };
}

function classifyError(error: unknown): AutomationErrorCode {
    if (isErrorWithCode<OAuthCredentialError>(error)) {
        if (error.code === "OAUTH_REAUTH_REQUIRED"
            || error.code === "OAUTH_SCOPE_MISSING"
            || error.code === "TRANSIENT_GITHUB_FAILURE") {
            return error.code;
        }
    }
    if (isErrorWithCode<PersonalProjectError>(error)) {
        if (error.code === "VISIBILITY_INDETERMINATE"
            || error.code === "PROJECT_API_INCOMPATIBLE"
            || error.code === "OAUTH_REAUTH_REQUIRED"
            || error.code === "OAUTH_SCOPE_MISSING"
            || error.code === "PROJECT_CONFIGURATION_INVALID"
            || error.code === "TRANSIENT_GITHUB_FAILURE") {
            return error.code;
        }
    }
    if (isErrorWithCode<RepositoryTruthError>(error)) {
        switch (error.code) {
        case "ISSUE_REPOSITORY_NOT_ACCESSIBLE":
        case "REPOSITORY_TRUTH_AUTHENTICATION_FAILED":
        case "REPOSITORY_TRUTH_FORBIDDEN":
        case "SOURCE_PULL_REQUEST_NOT_FOUND":
            return "ISSUE_REPOSITORY_NOT_ACCESSIBLE";
        case "GITHUB_RESPONSE_INVALID":
            return "PROJECT_API_INCOMPATIBLE";
        case "TRANSIENT_GITHUB_FAILURE":
            return "TRANSIENT_GITHUB_FAILURE";
        }
    }
    return "TRANSIENT_GITHUB_FAILURE";
}

function isErrorWithCode<T>(value: unknown): value is T & { code: string } {
    return typeof value === "object"
        && value !== null
        && "code" in value
        && typeof value.code === "string";
}

function retryDelay(attempt: number): number {
    return Math.min(60 * 2 ** Math.max(0, attempt - 1), 3_600);
}
