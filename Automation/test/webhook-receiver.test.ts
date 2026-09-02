import { describe, expect, test } from "vitest";
import {
    parsePullRequestWebhook,
    verifyWebhookSignature,
    WebhookRequestError,
} from "../src/webhook-receiver";

const encoder = new TextEncoder();

describe("verifyWebhookSignature", () => {
    test("accepts GitHub's published HMAC-SHA256 vector", async () => {
        const result = await verifyWebhookSignature(
            "It's a Secret to Everybody",
            "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17",
            encoder.encode("Hello, World!").buffer
        );

        expect(result).toBe(true);
    });

    test("rejects missing and malformed signatures", async () => {
        const body = encoder.encode("Hello, World!").buffer;

        await expect(verifyWebhookSignature("secret", null, body)).resolves.toBe(false);
        await expect(verifyWebhookSignature("secret", "sha256=not-hex", body)).resolves.toBe(false);
    });
});

describe("parsePullRequestWebhook", () => {
    test("keeps only the queue identity fields", () => {
        const payload = encoder.encode(JSON.stringify({
            action: "ready_for_review",
            installation: { id: 12, extra: "ignored" },
            repository: { id: 34, full_name: "private/repository" },
            pull_request: { number: 56, body: "private body" },
        })).buffer;

        expect(parsePullRequestWebhook(payload)).toEqual({
            action: "ready_for_review",
            installation: { id: 12 },
            repository: { id: 34 },
            pull_request: { number: 56 },
        });
    });

    test("rejects payloads without stable numeric identities", () => {
        const payload = encoder.encode(JSON.stringify({
            action: "opened",
            installation: { id: 12 },
            repository: { id: 34 },
            pull_request: { number: 0 },
        })).buffer;

        expect(() => parsePullRequestWebhook(payload)).toThrowError(WebhookRequestError);
    });
});
