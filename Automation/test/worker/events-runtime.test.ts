import { DurableObjectAutomationChangeNotifier } from "../../src/automation-events";
import { GitHubAppRequestError } from "../../src/github-app-client";
import { SELF } from "cloudflare:test";
import { beforeAll, expect, test } from "vitest";
import { InstallationLifecycleRunner } from "../../src/installation-lifecycle";
import { handleManagementRequest } from "../../src/management-api";
import { persistSetupCompletion } from "../../src/setup-completion";
import { testEnv, initializeDatabase, nextWebSocketMessage, seedConfigurableSetup, completionInput } from "./runtime-fixtures";

beforeAll(initializeDatabase);

test("streams project invalidations only to an authenticated automation connection", async () => {
    const setup = await seedConfigurableSetup("events", 141);
    const managementToken = "management-events";
    const automationID = await persistSetupCompletion(
        testEnv.DB,
        completionInput(setup, 1141, managementToken)
    );

    const unauthorized = await SELF.fetch("https://example.invalid/api/events", {
        headers: { Upgrade: "websocket" },
    });
    expect(unauthorized.status).toBe(401);

    const response = await SELF.fetch("https://example.invalid/api/events", {
        headers: {
            Authorization: `Bearer ${managementToken}`,
            Upgrade: "websocket",
        },
    });
    expect(response.status).toBe(101);
    const socket = response.webSocket;
    expect(socket).not.toBeNull();
    socket?.accept();

    await expect(nextWebSocketMessage(socket!)).resolves.toEqual({
        type: "ready",
        revision: 0,
    });
    const changed = nextWebSocketMessage(socket!);
    await testEnv.AUTOMATION_EVENTS.getByName(automationID).publish("project_data_changed");
    await expect(changed).resolves.toEqual({
        type: "project_data_changed",
        revision: 1,
    });
    const automationChanged = nextWebSocketMessage(socket!);
    await testEnv.AUTOMATION_EVENTS.getByName(automationID).publish("automation_changed");
    await expect(automationChanged).resolves.toEqual({
        type: "automation_changed",
        revision: 2,
    });
    socket?.close(1000, "test complete");
});

test.each([
    ["SUSPENDED", 151, 1], ["DELETED", 152, 1], ["SUSPENDED", 153, 0],
] as const)("notifies an existing socket for %s (%i) and recovers without enabling", async (initialState, installationID, enabled) => {
    const setup = await seedConfigurableSetup(`lifecycle-${installationID}`, installationID);
    const token = `management-lifecycle-${installationID}`;
    const automationID = await persistSetupCompletion(testEnv.DB, completionInput(setup, installationID, token));
    await testEnv.DB.prepare("UPDATE project_automations SET enabled = ? WHERE id = ?")
        .bind(enabled, automationID).run();
    const response = await SELF.fetch("https://example.invalid/api/events", {
        headers: { Authorization: `Bearer ${token}`, Upgrade: "websocket" },
    });
    const socket = response.webSocket!;
    socket.accept();
    await expect(nextWebSocketMessage(socket)).resolves.toEqual({ type: "ready", revision: 0 });
    let active = false;
    let failNotification = true;
    const notifier = new DurableObjectAutomationChangeNotifier(testEnv.AUTOMATION_EVENTS);
    const runner = new InstallationLifecycleRunner(testEnv.DB, {
        async getInstallation() {
            if (!active && initialState === "DELETED") throw new GitHubAppRequestError(404);
            return { id: installationID, accountID: installationID, accountType: "User",
                status: active ? "ACTIVE" as const : "SUSPENDED" as const };
        },
        async listInstallationRepositories() {
            return [{ id: installationID, nodeID: "REPOSITORY", nameWithOwner: "owner/repository" }];
        },
    }, {
        async publish(id, type) {
            if (failNotification) { failNotification = false; throw new Error("unavailable"); }
            await notifier.publish(id, type);
        },
    });
    const enqueue = async (id: string) => {
        const now = new Date().toISOString();
        await testEnv.DB.prepare(`INSERT INTO webhook_deliveries
            (delivery_id, installation_id, event_name, event_action, processing_state, received_at, state_updated_at)
            VALUES (?, ?, 'installation', 'unsuspend', 'QUEUED', ?, ?)`)
            .bind(id, installationID, now, now).run();
    };
    const stopped = `stopped-${installationID}`;
    await enqueue(stopped);
    expect((await runner.run(stopped, 1)).action).toBe("retry");
    const changed = nextWebSocketMessage(socket);
    expect((await runner.run(stopped, 2)).action).toBe("ack");
    await expect(changed).resolves.toEqual({ type: "automation_changed", revision: 1 });
    const readState = () => testEnv.DB.prepare(
        "SELECT enabled, health_state FROM project_automations WHERE id = ?"
    ).bind(automationID).first();
    expect(await readState()).toEqual({ enabled: 0, health_state: `INSTALLATION_${initialState}` });
    active = true;
    const recovered = `recovered-${installationID}`;
    await enqueue(recovered);
    const recoveryEvent = nextWebSocketMessage(socket);
    await runner.run(recovered, 1);
    await expect(recoveryEvent).resolves.toEqual({ type: "automation_changed", revision: 2 });
    expect(await readState()).toEqual({ enabled: 0, health_state: "CONTENT_VISIBILITY_UNVERIFIED" });
    const enable = await handleManagementRequest(new Request(
        `https://example.invalid/api/automations/${automationID}`, {
            method: "PATCH", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
            body: JSON.stringify({ enabled: true }),
        }
    ), testEnv);
    expect(enable.status).toBe(200);
    socket.close(1000, "test complete");
});
