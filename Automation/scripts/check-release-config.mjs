#!/usr/bin/env node

const requiredKeys = [
    "GITHUB_APP_ID",
    "GITHUB_APP_PRIVATE_KEY",
    "GITHUB_OAUTH_CLIENT_ID",
    "GITHUB_OAUTH_CLIENT_SECRET",
    "GITHUB_APP_SLUG",
    "GITHUB_WEBHOOK_SECRET",
    "OAUTH_TOKEN_ENCRYPTION_KEY",
    "PUBLIC_BASE_URL",
];

const errors = [];
const values = Object.fromEntries(requiredKeys.map((key) => [key, process.env[key]?.trim() ?? ""]));

for (const key of requiredKeys) {
    if (!values[key]) errors.push(`${key} is missing`);
}

if (values.GITHUB_APP_ID && !/^[1-9]\d*$/.test(values.GITHUB_APP_ID)) {
    errors.push("GITHUB_APP_ID must be a positive integer");
}
if (values.GITHUB_APP_SLUG && !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(values.GITHUB_APP_SLUG)) {
    errors.push("GITHUB_APP_SLUG must be a lowercase GitHub App slug");
}
if (values.GITHUB_APP_PRIVATE_KEY
    && !/^-----BEGIN (?:RSA )?PRIVATE KEY-----[\s\S]+-----END (?:RSA )?PRIVATE KEY-----$/.test(
        values.GITHUB_APP_PRIVATE_KEY.replace(/\\n/g, "\n")
    )) {
    errors.push("GITHUB_APP_PRIVATE_KEY must be a complete PEM private key");
}
if (values.GITHUB_WEBHOOK_SECRET && values.GITHUB_WEBHOOK_SECRET.length < 32) {
    errors.push("GITHUB_WEBHOOK_SECRET must contain at least 32 characters");
}
if (values.OAUTH_TOKEN_ENCRYPTION_KEY && !is32ByteBase64URL(values.OAUTH_TOKEN_ENCRYPTION_KEY)) {
    errors.push("OAUTH_TOKEN_ENCRYPTION_KEY must be a base64 or base64url encoded 32-byte key");
}
if (values.PUBLIC_BASE_URL) validatePublicBaseURL(values.PUBLIC_BASE_URL);

if (errors.length) {
    console.error("Release configuration is invalid:");
    for (const error of errors) console.error(`- ${error}`);
    process.exitCode = 1;
} else {
    console.log("Release configuration is valid");
}

function is32ByteBase64URL(value) {
    if (!/^[A-Za-z0-9+/_-]+={0,2}$/.test(value)) return false;
    try {
        const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
        return Buffer.from(normalized, "base64").byteLength === 32;
    } catch {
        return false;
    }
}

function validatePublicBaseURL(value) {
    try {
        const url = new URL(value);
        if (url.protocol !== "https:") errors.push("PUBLIC_BASE_URL must use HTTPS");
        if (url.username || url.password || url.search || url.hash) {
            errors.push("PUBLIC_BASE_URL must not contain credentials, a query, or a fragment");
        }
        if (url.pathname !== "/") errors.push("PUBLIC_BASE_URL must be an origin without a path");
    } catch {
        errors.push("PUBLIC_BASE_URL must be an absolute URL");
    }
}
