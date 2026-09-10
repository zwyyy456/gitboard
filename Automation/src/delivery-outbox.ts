import type { DeliveryMessage } from "./index";

interface PendingDelivery {
    delivery_id: string;
    event_name: string;
}

export const pullRequestDelaySeconds = 3;

export async function queueDelivery(
    database: D1Database,
    queue: Queue<DeliveryMessage>,
    deliveryID: string,
    delaySeconds = 0
): Promise<boolean> {
    try {
        await queue.send({ deliveryID }, { delaySeconds });
        await database.prepare(
            `UPDATE webhook_deliveries
             SET processing_state = 'QUEUED', state_updated_at = ?
             WHERE delivery_id = ? AND processing_state = 'RECEIVED'`
        ).bind(new Date().toISOString(), deliveryID).run();
        return true;
    } catch {
        return false;
    }
}

export async function flushDeliveryOutbox(
    database: D1Database,
    queue: Queue<DeliveryMessage>
): Promise<void> {
    const pending = await database.prepare(
        `SELECT delivery_id, event_name
         FROM webhook_deliveries
         WHERE processing_state = 'RECEIVED'
         ORDER BY received_at
         LIMIT 100`
    ).all<PendingDelivery>();

    for (const delivery of pending.results) {
        await queueDelivery(
            database, queue, delivery.delivery_id,
            delivery.event_name === "pull_request" ? pullRequestDelaySeconds : 0
        );
    }
}

export async function failExhaustedDelivery(
    database: D1Database,
    deliveryID: string
): Promise<void> {
    const now = new Date().toISOString();
    await database.prepare(
        `UPDATE webhook_deliveries
         SET processing_state = 'FAILED',
             error_code = COALESCE(error_code, 'RETRIES_EXHAUSTED'),
             completed_at = ?,
             state_updated_at = ?
         WHERE delivery_id = ?
           AND processing_state NOT IN ('COMPLETED', 'FAILED', 'IGNORED')`
    ).bind(now, now, deliveryID).run();
}
