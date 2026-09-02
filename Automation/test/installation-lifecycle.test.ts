import { describe, expect, test } from "vitest";
import { parseInstallationWebhook } from "../src/installation-lifecycle";

describe("parseInstallationWebhook", () => {
    test("retains only installation identity and lifecycle action", () => {
        const body = new TextEncoder().encode(JSON.stringify({
            action: "created",
            installation: {
                id: 12,
                account: { id: 34, type: "User", login: "private-login" },
                permissions: { issues: "read" },
            },
            repositories: [{ id: 56, full_name: "private/repository" }],
        })).buffer;

        expect(parseInstallationWebhook(body)).toEqual({
            action: "created",
            installationID: 12,
            accountID: 34,
            accountType: "User",
        });
    });
});
