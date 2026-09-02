const githubAPI = "https://api.github.com";

export interface InstallationRepository {
    id: number;
    nameWithOwner: string;
}

export class GitHubAppRequestError extends Error {
    constructor(readonly status: number) {
        super(`GitHub App request failed with status ${status}`);
    }
}

export class GitHubAppClient {
    constructor(
        private readonly appID: string,
        private readonly privateKey: string,
        private readonly apiVersion: string
    ) {}

    async createInstallationAccessToken(installationID: number): Promise<string> {
        const jwt = await createAppJWT(this.appID, this.privateKey);
        const response = await fetch(
            `${githubAPI}/app/installations/${installationID}/access_tokens`,
            {
                method: "POST",
                headers: this.headers(jwt),
                body: JSON.stringify({
                    permissions: {
                        issues: "read",
                        metadata: "read",
                        pull_requests: "read",
                    },
                }),
            }
        );
        if (!response.ok) {
            throw new GitHubAppRequestError(response.status);
        }
        const body: unknown = await response.json();
        if (!isRecord(body) || typeof body.token !== "string") {
            throw new GitHubAppRequestError(502);
        }
        return body.token;
    }

    async listInstallationRepositories(installationID: number): Promise<InstallationRepository[]> {
        const token = await this.createInstallationAccessToken(installationID);
        const repositories: InstallationRepository[] = [];
        let url: string | null = `${githubAPI}/installation/repositories?per_page=100`;

        while (url) {
            const response: Response = await fetch(url, { headers: this.headers(token) });
            if (!response.ok) {
                throw new GitHubAppRequestError(response.status);
            }
            const body: unknown = await response.json();
            if (!isRecord(body) || !Array.isArray(body.repositories)) {
                throw new GitHubAppRequestError(502);
            }
            for (const repository of body.repositories) {
                if (!isRecord(repository)
                    || !isPositiveInteger(repository.id)
                    || typeof repository.full_name !== "string") {
                    throw new GitHubAppRequestError(502);
                }
                repositories.push({
                    id: repository.id,
                    nameWithOwner: repository.full_name,
                });
            }
            url = nextPageURL(response.headers.get("Link"));
        }

        return repositories;
    }

    private headers(token: string): HeadersInit {
        return {
            Accept: "application/vnd.github+json",
            Authorization: `Bearer ${token}`,
            "Content-Type": "application/json",
            "User-Agent": "GitBoard-Automation",
            "X-GitHub-Api-Version": this.apiVersion,
        };
    }
}

export async function createAppJWT(
    appID: string,
    privateKeyPEM: string,
    now = Date.now()
): Promise<string> {
    const issuedAt = Math.floor(now / 1000);
    const header = base64URL(new TextEncoder().encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
    const claims = base64URL(new TextEncoder().encode(JSON.stringify({
        iat: issuedAt - 60,
        exp: issuedAt + 540,
        iss: appID,
    })));
    const signingInput = `${header}.${claims}`;
    const key = await crypto.subtle.importKey(
        "pkcs8",
        decodePEM(privateKeyPEM),
        { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
        false,
        ["sign"]
    );
    const signature = await crypto.subtle.sign(
        "RSASSA-PKCS1-v1_5",
        key,
        new TextEncoder().encode(signingInput)
    );
    return `${signingInput}.${base64URL(new Uint8Array(signature))}`;
}

function decodePEM(pem: string): ArrayBuffer {
    const isPKCS1 = pem.includes("-----BEGIN RSA PRIVATE KEY-----");
    const value = pem
        .replace(/-----BEGIN RSA PRIVATE KEY-----|-----END RSA PRIVATE KEY-----/g, "")
        .replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----/g, "")
        .replace(/\\n/g, "")
        .replace(/\s/g, "");
    const bytes = Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
    return isPKCS1 ? wrapPKCS1(bytes).buffer : bytes.buffer;
}

function wrapPKCS1(privateKey: Uint8Array<ArrayBuffer>): Uint8Array<ArrayBuffer> {
    const version = new Uint8Array([0x02, 0x01, 0x00]);
    const rsaAlgorithm = new Uint8Array([
        0x30, 0x0d,
        0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
        0x05, 0x00,
    ]);
    const privateKeyValue = concatBytes(
        new Uint8Array([0x04]),
        encodeDERLength(privateKey.byteLength),
        privateKey
    );
    const value = concatBytes(version, rsaAlgorithm, privateKeyValue);
    return concatBytes(new Uint8Array([0x30]), encodeDERLength(value.byteLength), value);
}

function encodeDERLength(length: number): Uint8Array<ArrayBuffer> {
    if (length < 0x80) {
        return new Uint8Array([length]);
    }
    const bytes: number[] = [];
    for (let value = length; value > 0; value >>= 8) {
        bytes.unshift(value & 0xff);
    }
    return new Uint8Array([0x80 | bytes.length, ...bytes]);
}

function concatBytes(...values: Uint8Array<ArrayBuffer>[]): Uint8Array<ArrayBuffer> {
    const result = new Uint8Array(new ArrayBuffer(
        values.reduce((length, value) => length + value.byteLength, 0)
    ));
    let offset = 0;
    for (const value of values) {
        result.set(value, offset);
        offset += value.byteLength;
    }
    return result;
}

function base64URL(bytes: Uint8Array): string {
    return btoa(String.fromCharCode(...bytes))
        .replace(/=/g, "")
        .replace(/\+/g, "-")
        .replace(/\//g, "_");
}

function nextPageURL(linkHeader: string | null): string | null {
    if (!linkHeader) {
        return null;
    }
    for (const value of linkHeader.split(",")) {
        const match = value.match(/<([^>]+)>;\s*rel="next"/);
        if (match) {
            return match[1];
        }
    }
    return null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
}

function isPositiveInteger(value: unknown): value is number {
    return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}
