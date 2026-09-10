import { describe, expect, test, vi } from "vitest";
import { flushDeliveryOutbox, queueDelivery } from "../src/delivery-outbox";
import type { DeliveryMessage } from "../src/index";

describe("delivery scheduling", () => {
    test("delays PR outbox recovery while installation events remain immediate", async () => {
        const send = vi.fn().mockResolvedValue(undefined);
        const statement = {
            bind: vi.fn().mockReturnThis(),
            run: vi.fn().mockResolvedValue({}),
            all: vi.fn().mockResolvedValue({ results: [
                { delivery_id: "pr", event_name: "pull_request" },
                { delivery_id: "installation", event_name: "installation" },
            ] }),
        };
        const database = { prepare: () => statement } as unknown as D1Database;
        const queue = { send } as unknown as Queue<DeliveryMessage>;
        await flushDeliveryOutbox(database, queue);
        expect(send.mock.calls).toEqual([
            [{ deliveryID: "pr" }, { delaySeconds: 3 }],
            [{ deliveryID: "installation" }, { delaySeconds: 0 }],
        ]);
    });

    test("a failed delayed send leaves the delivery available for recovery", async () => {
        const prepare = vi.fn();
        const database = { prepare } as unknown as D1Database;
        const queue = { send: vi.fn().mockRejectedValue(new Error("unavailable")) } as unknown as Queue<DeliveryMessage>;
        await expect(queueDelivery(database, queue, "pr", 3)).resolves.toBe(false);
        expect(prepare).not.toHaveBeenCalled();
    });
});
