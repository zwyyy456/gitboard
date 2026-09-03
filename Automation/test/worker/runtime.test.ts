import { env } from "cloudflare:workers";
import { applyD1Migrations, type D1Migration } from "cloudflare:test";
import { beforeAll, expect, test } from "vitest";
import type { Env } from "../../src/index";

interface TestEnvironment extends Env {
    TEST_MIGRATIONS: D1Migration[];
}

const testEnv = env as TestEnvironment;

beforeAll(async () => {
    await applyD1Migrations(testEnv.DB, testEnv.TEST_MIGRATIONS);
});

test("starts with the current D1 schema", async () => {
    const tables = await testEnv.DB.prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table'"
    ).all<{ name: string }>();

    expect(tables.results.map((table) => table.name)).toContain("project_automations");
});
