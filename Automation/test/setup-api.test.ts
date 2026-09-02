import { describe, expect, test } from "vitest";
import { handleSetupRequest } from "../src/setup-api";
import type { Env } from "../src/index";

describe("setup session", () => {
    test("returns the bearer secret once and stores only its hash", async () => {
        let values: unknown[] = [];
        const database = {
            prepare() {
                const statement = {
                    bind(...arguments_: unknown[]) {
                        values = arguments_;
                        return statement;
                    },
                    async run() {
                        return { meta: { changes: 1 } };
                    },
                };
                return statement;
            },
        } as unknown as D1Database;
        const response = await handleSetupRequest(
            new Request("https://automation.example/api/setup/sessions", { method: "POST" }),
            { DB: database, PUBLIC_BASE_URL: "https://automation.example" } as Env
        );
        const body = await response.json<{
            id: string;
            setupToken: string;
            authorizationURL: string;
        }>();

        expect(response.status).toBe(201);
        expect(body.authorizationURL).toBe(
            `https://automation.example/setup/${body.id}/oauth`
        );
        expect(body.setupToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
        expect(values[0]).toBe(body.id);
        expect(values[1]).not.toBe(body.setupToken);
        expect(values[1]).toMatch(/^[A-Za-z0-9_-]{43}$/);
    });
});
