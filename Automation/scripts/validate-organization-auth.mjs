#!/usr/bin/env node

import { createPrivateKey, sign } from "node:crypto";
import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { promisify } from "node:util";

const graphqlURL = "https://api.github.com/graphql";
const apiVersion = "2026-03-10";
const execFileAsync = promisify(execFile);

class ValidationError extends Error {}

function requiredEnvironment(name) {
    const value = process.env[name]?.trim();
    if (!value) {
        throw new ValidationError(`Missing required environment variable: ${name}`);
    }
    return value;
}

function positiveInteger(name) {
    const rawValue = requiredEnvironment(name);
    const value = Number(rawValue);
    if (!Number.isSafeInteger(value) || value <= 0) {
        throw new ValidationError(`${name} must be a positive integer`);
    }
    return value;
}

async function githubRequest(url, token, init = {}) {
    const response = await fetch(url, {
        ...init,
        headers: {
            Accept: "application/vnd.github+json",
            Authorization: `Bearer ${token}`,
            "X-GitHub-Api-Version": apiVersion,
            "User-Agent": "GitBoard-organization-boundary-validator",
            ...init.headers,
        },
    });
    const body = await response.json().catch(() => null);
    if (!response.ok) {
        const message = body?.message ?? `HTTP ${response.status}`;
        throw new ValidationError(`GitHub request failed: ${message}`);
    }
    return body;
}

async function graphQL(token, query, variables) {
    const body = await githubRequest(graphqlURL, token, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query, variables }),
    });
    if (body.errors?.length) {
        throw new ValidationError(
            `GraphQL request failed: ${body.errors.map((error) => error.message).join("; ")}`
        );
    }
    return body.data;
}

function base64URL(value) {
    return Buffer.from(value).toString("base64url");
}

async function mintOrganizationInstallationToken() {
    const appID = requiredEnvironment("GB_GITHUB_APP_ID");
    const installationID = requiredEnvironment("GB_ORGANIZATION_INSTALLATION_ID");
    const privateKeyPath = requiredEnvironment("GB_GITHUB_APP_PRIVATE_KEY_PATH");
    const privateKey = createPrivateKey(await readFile(privateKeyPath));
    const now = Math.floor(Date.now() / 1_000);
    const header = base64URL(JSON.stringify({ alg: "RS256", typ: "JWT" }));
    const payload = base64URL(JSON.stringify({ iat: now - 60, exp: now + 9 * 60, iss: appID }));
    const unsignedToken = `${header}.${payload}`;
    const signature = sign("RSA-SHA256", Buffer.from(unsignedToken), privateKey).toString("base64url");
    const jwt = `${unsignedToken}.${signature}`;
    const body = await githubRequest(
        `https://api.github.com/app/installations/${encodeURIComponent(installationID)}/access_tokens`,
        jwt,
        { method: "POST" }
    );
    if (!body?.token) {
        throw new ValidationError("GitHub App did not return an organization installation access token");
    }
    console.log("✓ Organization installation token generated in memory");
    return body.token;
}

async function loadOrganizationProject(token, organization, projectNumber) {
    const items = [];
    let project;
    let cursor = null;
    do {
        const data = await graphQL(
            token,
            `query OrganizationProject($organization: String!, $number: Int!, $cursor: String) {
              organization(login: $organization) {
                projectV2(number: $number) {
                  id
                  fields(first: 100) {
                    nodes {
                      ... on ProjectV2SingleSelectField {
                        id
                        name
                        options { id name }
                      }
                    }
                  }
                  items(first: 100, after: $cursor) {
                    nodes {
                      id
                      content {
                        __typename
                        ... on Issue { id }
                        ... on PullRequest { id }
                      }
                      fieldValueByName(name: "Status") {
                        ... on ProjectV2ItemFieldSingleSelectValue { optionId }
                      }
                    }
                    pageInfo { hasNextPage endCursor }
                  }
                }
              }
            }`,
            { organization, number: projectNumber, cursor }
        );
        const pageProject = data.organization?.projectV2;
        if (!pageProject) {
            throw new ValidationError("Organization installation token could not read the configured Project");
        }
        project ??= pageProject;
        items.push(...pageProject.items.nodes);
        cursor = pageProject.items.pageInfo.hasNextPage
            ? pageProject.items.pageInfo.endCursor
            : null;
    } while (cursor);

    const statusField = project.fields.nodes.find((field) => field?.name === "Status");
    if (!statusField) {
        throw new ValidationError("The configured organization Project has no single-select Status field");
    }
    return { id: project.id, items, statusField };
}

async function loadOrganizationProjectWithGH(organization, projectNumber) {
    let token;
    try {
        const result = await execFileAsync("gh", ["auth", "token", "--hostname", "github.com"]);
        token = result.stdout.trim();
    } catch {
        throw new ValidationError("Local gh could not read the authenticated GitHub token");
    }
    if (!token) {
        throw new ValidationError("Local gh returned an empty GitHub token");
    }
    return loadOrganizationProject(token, organization, projectNumber);
}

async function updateStatus(token, projectID, itemID, fieldID, optionID) {
    const data = await graphQL(
        token,
        `mutation UpdateStatus($project: ID!, $item: ID!, $field: ID!, $option: String!) {
          updateProjectV2ItemFieldValue(input: {
            projectId: $project
            itemId: $item
            fieldId: $field
            value: { singleSelectOptionId: $option }
          }) {
            projectV2Item {
              id
              fieldValueByName(name: "Status") {
                ... on ProjectV2ItemFieldSingleSelectValue { optionId }
              }
            }
          }
        }`,
        { project: projectID, item: itemID, field: fieldID, option: optionID }
    );
    return data.updateProjectV2ItemFieldValue?.projectV2Item?.fieldValueByName?.optionId ?? null;
}

async function clearStatus(token, projectID, itemID, fieldID) {
    const data = await graphQL(
        token,
        `mutation ClearStatus($project: ID!, $item: ID!, $field: ID!) {
          clearProjectV2ItemFieldValue(input: {
            projectId: $project
            itemId: $item
            fieldId: $field
          }) {
            projectV2Item {
              id
              fieldValueByName(name: "Status") {
                ... on ProjectV2ItemFieldSingleSelectValue { optionId }
              }
            }
          }
        }`,
        { project: projectID, item: itemID, field: fieldID }
    );
    return data.clearProjectV2ItemFieldValue?.projectV2Item?.fieldValueByName?.optionId ?? null;
}

function printUsage() {
    console.log(`Usage: node Automation/scripts/validate-organization-auth.mjs

Required environment:
  GB_ORGANIZATION
  GB_PROJECT_NUMBER
  GB_PROJECT_NODE_ID
  GB_PROJECT_ITEM_NODE_ID
  GB_CONTENT_NODE_ID

Recommended GitHub App inputs:
  GB_GITHUB_APP_ID
  GB_ORGANIZATION_INSTALLATION_ID
  GB_GITHUB_APP_PRIVATE_KEY_PATH

Optional inputs:
  GB_ORGANIZATION_INSTALLATION_TOKEN
  GB_TARGET_STATUS_OPTION_ID`);
}

async function main() {
    const argumentsList = process.argv.slice(2);
    if (argumentsList.includes("--help")) {
        printUsage();
        return;
    }
    if (argumentsList.length) {
        throw new ValidationError(`Unknown argument: ${argumentsList[0]}`);
    }

    const organization = requiredEnvironment("GB_ORGANIZATION");
    const projectNumber = positiveInteger("GB_PROJECT_NUMBER");
    const expectedProjectID = requiredEnvironment("GB_PROJECT_NODE_ID");
    const expectedItemID = requiredEnvironment("GB_PROJECT_ITEM_NODE_ID");
    const expectedContentID = requiredEnvironment("GB_CONTENT_NODE_ID");
    const installationToken = process.env.GB_ORGANIZATION_INSTALLATION_TOKEN?.trim()
        || await mintOrganizationInstallationToken();

    const project = await loadOrganizationProject(installationToken, organization, projectNumber);
    if (project.id !== expectedProjectID) {
        throw new ValidationError("Webhook project_node_id does not match the configured organization Project");
    }
    console.log("✓ Webhook project_node_id matches the organization Project");
    console.log(`✓ Organization installation token scanned ${project.items.length} Project item(s)`);

    const scannedItem = project.items.find((candidate) => candidate.id === expectedItemID) ?? null;
    const scannedContentID = scannedItem?.content?.id ?? null;
    if (scannedContentID && scannedContentID !== expectedContentID) {
        throw new ValidationError("Full scan returned a different content node ID for the webhook Project item");
    }
    if (scannedContentID && scannedItem.content.__typename !== "Issue") {
        throw new ValidationError("Full scan resolved the webhook content as a non-Issue item");
    }
    const requiresDesktopMapping = scannedContentID !== expectedContentID;

    let item = scannedItem;
    if (requiresDesktopMapping) {
        console.log("• Organization full scan hid the personal private Issue mapping");
        const controlProject = await loadOrganizationProjectWithGH(organization, projectNumber);
        item = controlProject.items.find((candidate) => candidate.id === expectedItemID) ?? null;
        if (!item || item.content?.id !== expectedContentID || item.content.__typename !== "Issue") {
            throw new ValidationError("Local gh could not resolve the webhook item to the personal private Issue");
        }
        console.log("✓ Local gh supplied the hidden Issue-to-Project-item mapping and original Status");
    } else {
        console.log("✓ Organization full scan matched the personal private Issue content node ID");
    }

    const originalStatusOptionID = item.fieldValueByName?.optionId ?? null;
    const configuredTargetStatusOptionID = process.env.GB_TARGET_STATUS_OPTION_ID?.trim();
    const optionIDs = new Set(project.statusField.options.map((option) => option.id));
    if (configuredTargetStatusOptionID && !optionIDs.has(configuredTargetStatusOptionID)) {
        throw new ValidationError("GB_TARGET_STATUS_OPTION_ID is not an option in the Project Status field");
    }
    const targetStatusOptionID = configuredTargetStatusOptionID
        ?? project.statusField.options.find((option) => option.id !== originalStatusOptionID)?.id;
    if (!targetStatusOptionID) {
        throw new ValidationError("The Project needs a Status option different from the item's current value");
    }
    if (targetStatusOptionID === originalStatusOptionID) {
        throw new ValidationError("Target Status option must differ from the current Status option");
    }

    let mutationApplied = false;
    try {
        const updatedStatusOptionID = await updateStatus(
            installationToken,
            project.id,
            item.id,
            project.statusField.id,
            targetStatusOptionID
        );
        mutationApplied = true;
        if (updatedStatusOptionID !== targetStatusOptionID) {
            throw new ValidationError("Organization installation token did not apply the target Status");
        }
        console.log("✓ Organization installation token updated the Project item Status");
    } finally {
        if (mutationApplied) {
            const restoredStatusOptionID = originalStatusOptionID
                ? await updateStatus(
                    installationToken,
                    project.id,
                    item.id,
                    project.statusField.id,
                    originalStatusOptionID
                )
                : await clearStatus(
                    installationToken,
                    project.id,
                    item.id,
                    project.statusField.id
                );
            if (restoredStatusOptionID !== originalStatusOptionID) {
                throw new ValidationError("Project item Status could not be restored to its original value");
            }
            console.log("✓ Original Project item Status restored");
        }
    }

    if (requiresDesktopMapping) {
        console.log("Organization boundary validation passed: desktop mapping initialization is required");
    } else {
        console.log("Organization boundary validation passed: organization full scan can initialize mappings");
    }
}

main().catch((error) => {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`Validation failed: ${message}`);
    process.exitCode = 1;
});
