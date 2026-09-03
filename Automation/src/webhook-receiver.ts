import { queueDelivery } from "./delivery-outbox";
import type { Env } from "./index";
import { receiveInstallationWebhook } from "./installation-lifecycle";

const pullRequestActions = new Set([
    "closed",
    "converted_to_draft",
    "edited",
    "opened",
    "ready_for_review",
    "reopened",
]);

interface PullRequestWebhook {
    action: string;
    installation: { id: number };
    repository: { id: number };
    pull_request: { number: number };
}

interface DeliveryRecord {
    processing_state: string;
}

export class WebhookRequestError extends Error {
    constructor(
        readonly status: number,
        readonly code: string
    ) {
        super(code);
    }
}

export async function receiveGitHubWebhook(request: Request, env: Env): Promise<Response> {
    const body = await request.arrayBuffer();
    const signature = request.headers.get("X-Hub-Signature-256");
    if (!await verifyWebhookSignature(env.GITHUB_WEBHOOK_SECRET, signature, body)) {
        throw new WebhookRequestError(401, "INVALID_WEBHOOK_SIGNATURE");
    }

    const eventName = request.headers.get("X-GitHub-Event");
    if (eventName === "ping") {
        return new Response(null, { status: 204 });
    }
    if (eventName === "installation" || eventName === "installation_repositories") {
        return receiveInstallationWebhook(eventName, body, env);
    }
    if (eventName !== "pull_request") {
        return Response.json({ accepted: false, reason: "unsupported_event" }, { status: 202 });
    }

    const deliveryID = request.headers.get("X-GitHub-Delivery");
    if (!deliveryID) {
        throw new WebhookRequestError(400, "MISSING_DELIVERY_ID");
    }

    const payload = parsePullRequestWebhook(body);
    if (!pullRequestActions.has(payload.action)) {
        return Response.json({ accepted: false, reason: "unsupported_action" }, { status: 202 });
    }

    const automation = await env.DB.prepare(
        `SELECT id
         FROM project_automations
         WHERE installation_id = ? AND repository_id = ? AND enabled = 1
         LIMIT 1`
    ).bind(payload.installation.id, payload.repository.id).first<{ id: string }>();
    if (!automation) {
        return Response.json({ accepted: false, reason: "automation_not_found" }, { status: 202 });
    }

    const now = new Date().toISOString();
    const insertion = await env.DB.prepare(
        `INSERT OR IGNORE INTO webhook_deliveries (
            delivery_id, automation_id, installation_id, repository_id,
            pull_request_number, event_name, event_action, processing_state,
            attempt_count, received_at, state_updated_at
         ) VALUES (?, ?, ?, ?, ?, 'pull_request', ?, 'RECEIVED', 0, ?, ?)`
    ).bind(
        deliveryID,
        automation.id,
        payload.installation.id,
        payload.repository.id,
        payload.pull_request.number,
        payload.action,
        now,
        now
    ).run();

    if (insertion.meta.changes === 0) {
        const existing = await env.DB.prepare(
            "SELECT processing_state FROM webhook_deliveries WHERE delivery_id = ?"
        ).bind(deliveryID).first<DeliveryRecord>();
        if (existing?.processing_state !== "RECEIVED") {
            return Response.json({ accepted: true, duplicate: true }, { status: 202 });
        }
    }

    const queued = await queueDelivery(env.DB, env.AUTOMATION_QUEUE, deliveryID);
    console.info("automation_delivery_persisted", {
        deliveryID,
        automationID: automation.id,
        queued,
    });

    return Response.json({ accepted: true }, { status: 202 });
}

export async function verifyWebhookSignature(
    secret: string,
    signatureHeader: string | null,
    body: ArrayBuffer
): Promise<boolean> {
    if (!signatureHeader?.startsWith("sha256=")) {
        return false;
    }
    const signature = decodeHex(signatureHeader.slice("sha256=".length));
    if (!signature || signature.byteLength !== 32) {
        return false;
    }
    const key = await crypto.subtle.importKey(
        "raw",
        new TextEncoder().encode(secret),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["verify"]
    );
    return crypto.subtle.verify("HMAC", key, signature, body);
}

export function parsePullRequestWebhook(body: ArrayBuffer): PullRequestWebhook {
    let value: unknown;
    try {
        value = JSON.parse(new TextDecoder().decode(body));
    } catch {
        throw new WebhookRequestError(400, "INVALID_WEBHOOK_PAYLOAD");
    }
    if (!isRecord(value)
        || typeof value.action !== "string"
        || !isRecord(value.installation)
        || !isPositiveInteger(value.installation.id)
        || !isRecord(value.repository)
        || !isPositiveInteger(value.repository.id)
        || !isRecord(value.pull_request)
        || !isPositiveInteger(value.pull_request.number)) {
        throw new WebhookRequestError(400, "INVALID_WEBHOOK_PAYLOAD");
    }
    return {
        action: value.action,
        installation: { id: value.installation.id },
        repository: { id: value.repository.id },
        pull_request: { number: value.pull_request.number },
    };
}

function decodeHex(value: string): Uint8Array<ArrayBuffer> | null {
    if (value.length % 2 !== 0 || !/^[0-9a-f]+$/i.test(value)) {
        return null;
    }
    const bytes = new Uint8Array(new ArrayBuffer(value.length / 2));
    for (let index = 0; index < bytes.length; index += 1) {
        bytes[index] = Number.parseInt(value.slice(index * 2, index * 2 + 2), 16);
    }
    return bytes;
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
}

function isPositiveInteger(value: unknown): value is number {
    return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}
