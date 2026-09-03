import type { DeliveryMessage } from "./index";

interface PendingDelivery {
    delivery_id: string;
}

export async function queueDelivery(
    database: D1Database,
    queue: Queue<DeliveryMessage>,
    deliveryID: string
): Promise<boolean> {
    try {
        await queue.send({ deliveryID });
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
        `SELECT delivery_id
         FROM webhook_deliveries
         WHERE processing_state = 'RECEIVED'
         ORDER BY received_at
         LIMIT 100`
    ).all<PendingDelivery>();

    for (const delivery of pending.results) {
        await queueDelivery(database, queue, delivery.delivery_id);
    }
}
