import { afterEach, describe, expect, test, vi } from "vitest";
import { createAppJWT, GitHubAppClient } from "../src/github-app-client";

afterEach(() => vi.unstubAllGlobals());

describe("createAppJWT", () => {
    test("creates a verifiable RS256 token with GitHub's required claims", async () => {
        const keyPair = await crypto.subtle.generateKey(
            {
                name: "RSASSA-PKCS1-v1_5",
                modulusLength: 2048,
                publicExponent: new Uint8Array([1, 0, 1]),
                hash: "SHA-256",
            },
            true,
            ["sign", "verify"]
        );
        const privateKey = await crypto.subtle.exportKey("pkcs8", keyPair.privateKey);
        const pem = toPEM(privateKey);
        const now = Date.UTC(2026, 8, 2, 12, 0, 0);

        const token = await createAppJWT("12345", pem, now);
        const [header, claims, signature] = token.split(".");

        expect(JSON.parse(decodeBase64URL(header))).toEqual({ alg: "RS256", typ: "JWT" });
        expect(JSON.parse(decodeBase64URL(claims))).toEqual({
            iat: Math.floor(now / 1000) - 60,
            exp: Math.floor(now / 1000) + 540,
            iss: "12345",
        });
        await expect(crypto.subtle.verify(
            "RSASSA-PKCS1-v1_5",
            keyPair.publicKey,
            decodeBytes(signature),
            new TextEncoder().encode(`${header}.${claims}`)
        )).resolves.toBe(true);
    });

    test("accepts GitHub's PKCS#1 private key format", async () => {
        await expect(createAppJWT("12345", pkcs1PrivateKey)).resolves.toMatch(
            /^[^.]+\.[^.]+\.[^.]+$/
        );
    });
});

describe("GitHubAppClient", () => {
    test("retains repository node identity from an installation", async () => {
        vi.stubGlobal("fetch", vi.fn()
            .mockResolvedValueOnce(Response.json({ token: "installation-token" }))
            .mockResolvedValueOnce(Response.json({
                repositories: [{
                    id: 7,
                    node_id: "REPOSITORY_NODE",
                    full_name: "owner/repository",
                }],
            })));
        const client = new GitHubAppClient("12345", pkcs1PrivateKey, "2026-03-10");

        await expect(client.listInstallationRepositories(9)).resolves.toEqual([{
            id: 7,
            nodeID: "REPOSITORY_NODE",
            nameWithOwner: "owner/repository",
        }]);
    });
});

const pkcs1PrivateKey = `-----BEGIN RSA PRIVATE KEY-----
MIICXQIBAAKBgQD4ntRLjej0xDiyjhF/DOlLjpq4rf8D5xWvSLifi8UkYR6R5D2/
vVYMwvIGn5GtbM5VV8pY2fAk/qLYQMVD8DXoJSTdF3k9uNL5cN0NnJs+ckuCC7bH
aFhE1uvpIFE8df3xwnyjo2dwp4DLRqq+cBcwLA06wpmnLIP+8/ZoNgjI6wIDAQAB
AoGBANaEHMMQL/e5sv4FbP1Fw6oI4mEE6GuSoPg78+jdrX1lOv5AhDMDh9K9Bh1G
42hS4HlspVAiw3z4JMQYptymz6rJuULGrXGnFLxCzPz7AJ9swGR0jy9bTTNyNBnt
Qq1pNVD5Tw6BoefN4icph0EEzbT3ZVBICPcEZgK9KlqV79+xAkEA/pHbHfypSTW3
+ZTvlxd46d7dn3H8icv5lY7aw5ZeBcweFgwt27QYCGvBW273bALLbr4PPmSuwCiq
Y9lWYVWFUwJBAPoEaqFawEQbJrr4rMFgpclTxyWWSX9lrZNMh/0RPGV9MMEyR5vG
luBBjM+aIYhcg1H/5UCqFaGUF4IbH8OoYwkCQFMCSIrcqm6+34C4ue9wrfLEw0uM
paZhJr9H17nTPFFzn5Pc4M81SGjmiiRAaNmFh8RSoTHdLsZl/DmW0v3mHxUCQQDw
qMerQZvI8wm4+B3yloF+5fHQMHXW95y5KPXNl4W3e2Yu0aM0Q1h/zRkpzIdypvqR
N+0I7a+ctNxcFJfi0ndhAkBFJQTxcChniWl2UBFiO3q8+yxTRvV8CLRBNciboe/d
Aa/r4nSjmkCBBPSZKla20Dd6EuIIxx+UInKCo1llyZh1
-----END RSA PRIVATE KEY-----`;

function toPEM(value: ArrayBuffer): string {
    const base64 = btoa(String.fromCharCode(...new Uint8Array(value)));
    return `-----BEGIN PRIVATE KEY-----\n${base64}\n-----END PRIVATE KEY-----`;
}

function decodeBase64URL(value: string): string {
    return new TextDecoder().decode(decodeBytes(value));
}

function decodeBytes(value: string): Uint8Array<ArrayBuffer> {
    const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
    const padding = "=".repeat((4 - base64.length % 4) % 4);
    return Uint8Array.from(atob(base64 + padding), (character) => character.charCodeAt(0));
}
