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
            "User-Agent": "GitBoard-authorization-validator",
            ...init.headers,
        },
    });
    const body = await response.json().catch(() => null);
    if (!response.ok) {
        const message = body?.message ?? `HTTP ${response.status}`;
        throw new ValidationError(`GitHub request failed: ${message}`);
    }
    return { body, headers: response.headers };
}

async function graphQL(token, query, variables) {
    const { body } = await githubRequest(graphqlURL, token, {
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

async function oauthRequest(parameters) {
    const response = await fetch("https://github.com/login/oauth/access_token", {
        method: "POST",
        headers: {
            Accept: "application/json",
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "GitBoard-authorization-validator",
        },
        body: new URLSearchParams(parameters),
    });
    const body = await response.json().catch(() => null);
    return { response, body };
}

async function rotateOAuthToken({ clientID, clientSecret, refreshToken }) {
    const parameters = {
        client_id: clientID,
        grant_type: "refresh_token",
        refresh_token: refreshToken,
    };
    if (clientSecret) parameters.client_secret = clientSecret;
    const { response, body } = await oauthRequest(parameters);
    if (!response.ok || !body?.access_token || !body?.refresh_token) {
        throw new ValidationError(`OAuth refresh failed: ${body?.error_description ?? body?.error ?? response.status}`);
    }
    if (!Number.isFinite(body.expires_in) || !Number.isFinite(body.refresh_token_expires_in)) {
        throw new ValidationError("OAuth refresh response did not contain token expiration values");
    }
    return body.access_token;
}

async function oauthDeviceFlow() {
    const clientID = requiredEnvironment("GB_OAUTH_CLIENT_ID");
    const startResponse = await fetch("https://github.com/login/device/code", {
        method: "POST",
        headers: {
            Accept: "application/json",
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "GitBoard-authorization-validator",
        },
        body: new URLSearchParams({ client_id: clientID, scope: "project offline_access" }),
    });
    const start = await startResponse.json().catch(() => null);
    if (!startResponse.ok || !start?.device_code || !start?.user_code || !start?.verification_uri) {
        throw new ValidationError(`OAuth device flow could not start: ${start?.error_description ?? start?.error ?? startResponse.status}`);
    }

    console.log(`Open ${start.verification_uri} and enter code ${start.user_code}`);
    let intervalSeconds = start.interval;
    const expiresAt = Date.now() + start.expires_in * 1_000;
    while (Date.now() < expiresAt) {
        await new Promise((resolve) => setTimeout(resolve, intervalSeconds * 1_000));
        const { body } = await oauthRequest({
            client_id: clientID,
            device_code: start.device_code,
            grant_type: "urn:ietf:params:oauth:grant-type:device_code",
        });
        if (body?.access_token) {
            if (!body.refresh_token || !Number.isFinite(body.expires_in) || !Number.isFinite(body.refresh_token_expires_in)) {
                throw new ValidationError("OAuth device flow did not return an expiring access/refresh token pair");
            }
            console.log("✓ OAuth project/offline_access device authorization succeeded");
            return {
                accessToken: body.access_token,
                clientID,
                refreshToken: body.refresh_token,
            };
        }
        if (body?.error === "authorization_pending") continue;
        if (body?.error === "slow_down") {
            intervalSeconds += 5;
            continue;
        }
        throw new ValidationError(`OAuth device authorization failed: ${body?.error_description ?? body?.error ?? "unknown error"}`);
    }
    throw new ValidationError("OAuth device authorization expired before it was approved");
}

function base64URL(value) {
    return Buffer.from(value).toString("base64url");
}

async function mintInstallationToken() {
    const appID = requiredEnvironment("GB_GITHUB_APP_ID");
    const installationID = requiredEnvironment("GB_INSTALLATION_ID");
    const privateKeyPath = requiredEnvironment("GB_GITHUB_APP_PRIVATE_KEY_PATH");
    const privateKey = createPrivateKey(await readFile(privateKeyPath));
    const now = Math.floor(Date.now() / 1_000);
    const header = base64URL(JSON.stringify({ alg: "RS256", typ: "JWT" }));
    const payload = base64URL(JSON.stringify({ iat: now - 60, exp: now + 9 * 60, iss: appID }));
    const unsignedToken = `${header}.${payload}`;
    const signature = sign("RSA-SHA256", Buffer.from(unsignedToken), privateKey).toString("base64url");
    const jwt = `${unsignedToken}.${signature}`;
    const { body } = await githubRequest(
        `https://api.github.com/app/installations/${encodeURIComponent(installationID)}/access_tokens`,
        jwt,
        { method: "POST" }
    );
    if (!body?.token) {
        throw new ValidationError("GitHub App did not return an installation access token");
    }
    console.log("✓ GitHub App installation token generated in memory");
    return body.token;
}

async function loadOAuthIdentity(token) {
    const { body, headers } = await githubRequest("https://api.github.com/user", token);
    const scopes = new Set(
        (headers.get("x-oauth-scopes") ?? "")
            .split(",")
            .map((scope) => scope.trim())
            .filter(Boolean)
    );
    if (!scopes.has("project")) {
        throw new ValidationError("OAuth token is missing the project scope");
    }
    const unexpectedScopes = [...scopes].filter((scope) => scope !== "project");
    if (unexpectedScopes.length) {
        throw new ValidationError(`OAuth token has unexpected scope: ${unexpectedScopes[0]}`);
    }
    return { nodeID: body.node_id, login: body.login };
}

async function loadClosingIssues(token, repositoryOwner, repositoryName, pullRequestNumber) {
    const data = await graphQL(
        token,
        `query ClosingIssues($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            owner { id login }
            pullRequest(number: $number) {
              closingIssuesReferences(first: 100) {
                nodes { id number repository { nameWithOwner } }
              }
            }
          }
        }`,
        { owner: repositoryOwner, name: repositoryName, number: pullRequestNumber }
    );
    const pullRequest = data.repository?.pullRequest;
    if (!pullRequest) {
        throw new ValidationError("Installation token could not read the configured pull request");
    }
    const issues = pullRequest.closingIssuesReferences.nodes;
    if (!issues.length) {
        throw new ValidationError("The pull request has no formal closing Issue relationship");
    }
    return { issues, repositoryOwner: data.repository.owner };
}

async function loadProject(token, owner, number) {
    const data = await graphQL(
        token,
        `query PersonalProject($owner: String!, $number: Int!) {
          user(login: $owner) {
            projectV2(number: $number) {
              id
              title
              fields(first: 100) {
                nodes {
                  ... on ProjectV2SingleSelectField {
                    id
                    name
                    options { id name }
                  }
                }
              }
            }
          }
        }`,
        { owner, number }
    );
    const project = data.user?.projectV2;
    if (!project) {
        throw new ValidationError("OAuth token could not read the configured personal Project");
    }
    const statusField = project.fields.nodes.find((field) => field?.name === "Status");
    if (!statusField) {
        throw new ValidationError("The configured Project has no single-select Status field");
    }
    return { ...project, statusField };
}

async function loadProjectItems(token, owner, projectNumber) {
    const result = [];
    let cursor = null;
    do {
        const data = await graphQL(
            token,
            `query PersonalProjectItems($owner: String!, $number: Int!, $cursor: String) {
              user(login: $owner) {
                projectV2(number: $number) {
                  items(first: 100, after: $cursor) {
                    nodes {
                      id
                      content { ... on Issue { id } }
                      fieldValueByName(name: "Status") {
                        ... on ProjectV2ItemFieldSingleSelectValue { optionId }
                      }
                    }
                    pageInfo { hasNextPage endCursor }
                  }
                }
              }
            }`,
            { owner, number: projectNumber, cursor }
        );
        const items = data.user?.projectV2?.items;
        if (!items) {
            throw new ValidationError("OAuth token could not enumerate personal Project items");
        }
        result.push(...items.nodes);
        cursor = items.pageInfo.hasNextPage ? items.pageInfo.endCursor : null;
    } while (cursor);
    return result;
}

function nextPageURL(linkHeader) {
    if (!linkHeader) return null;
    for (const value of linkHeader.split(",")) {
        const match = value.match(/<([^>]+)>;\s*rel="next"/);
        if (match) return match[1];
    }
    return null;
}

async function loadFilteredProjectItemsViaREST(token, owner, projectNumber, filter) {
    const firstURL = new URL(
        `https://api.github.com/users/${encodeURIComponent(owner)}/projectsV2/${projectNumber}/items`
    );
    firstURL.searchParams.set("per_page", "100");
    firstURL.searchParams.set("q", filter);

    const result = [];
    let url = firstURL.toString();
    while (url) {
        const { body, headers } = await githubRequest(url, token);
        if (!Array.isArray(body)) {
            throw new ValidationError("REST personal Project items response was not an array");
        }
        result.push(...body);
        url = nextPageURL(headers.get("link"));
    }
    return result;
}

function classifyFilteredItem(items, expectedItemID, expectedContentID, itemID, contentID) {
    const item = items.find((candidate) => itemID(candidate) === expectedItemID);
    if (!item) return "missing";
    return contentID(item) === expectedContentID ? "complete" : "redacted";
}

async function findProjectItem(token, owner, projectNumber, issueIDs) {
    const items = await loadProjectItems(token, owner, projectNumber);
    return items.find((candidate) => issueIDs.has(candidate.content?.id)) ?? null;
}

async function findProjectItemViaInstallation(token, issueIDs, projectItemIDs) {
    for (const issueID of issueIDs) {
        let cursor = null;
        do {
            const data = await graphQL(
                token,
                `query IssueProjectItems($issue: ID!, $cursor: String) {
                  node(id: $issue) {
                    ... on Issue {
                      projectItems(first: 100, after: $cursor) {
                        nodes { id }
                        pageInfo { hasNextPage endCursor }
                      }
                    }
                  }
                }`,
                { issue: issueID, cursor }
            );
            const items = data.node?.projectItems;
            if (!items) break;
            const item = items.nodes.find((candidate) => projectItemIDs.has(candidate.id));
            if (item) return item.id;
            cursor = items.pageInfo.hasNextPage ? items.pageInfo.endCursor : null;
        } while (cursor);
    }
    return null;
}

async function findProjectItemWithGH(owner, projectNumber, issueIDs) {
    let token;
    try {
        const result = await execFileAsync("gh", ["auth", "token", "--hostname", "github.com"]);
        token = result.stdout.trim();
    } catch {
        throw new ValidationError("gh control could not read the authenticated GitHub token");
    }
    if (!token) {
        throw new ValidationError("gh control returned an empty GitHub token");
    }
    return findProjectItem(token, owner, projectNumber, issueIDs);
}

async function updateStatus(token, projectID, itemID, fieldID, optionID) {
    await graphQL(
        token,
        `mutation UpdateStatus($project: ID!, $item: ID!, $field: ID!, $option: String!) {
          updateProjectV2ItemFieldValue(input: {
            projectId: $project
            itemId: $item
            fieldId: $field
            value: { singleSelectOptionId: $option }
          }) { projectV2Item { id } }
        }`,
        { project: projectID, item: itemID, field: fieldID, option: optionID }
    );
}

async function clearStatus(token, projectID, itemID, fieldID) {
    await graphQL(
        token,
        `mutation ClearStatus($project: ID!, $item: ID!, $field: ID!) {
          clearProjectV2ItemFieldValue(input: {
            projectId: $project
            itemId: $item
            fieldId: $field
          }) { projectV2Item { id } }
        }`,
        { project: projectID, item: itemID, field: fieldID }
    );
}

function printUsage() {
    console.log(`Usage: node Automation/scripts/validate-personal-auth.mjs [--device-flow] [--rotate-refresh-token] [--gh-control | --gh-mapping | --project-filter-probe]

Required environment:
  GB_REPOSITORY                 owner/repository
  GB_PR_NUMBER
  GB_PROJECT_OWNER
  GB_PROJECT_NUMBER

Recommended GitHub App inputs:
  GB_GITHUB_APP_ID
  GB_INSTALLATION_ID
  GB_GITHUB_APP_PRIVATE_KEY_PATH

Recommended OAuth device-flow input:
  GB_OAUTH_CLIENT_ID

Optional direct-token inputs:
  GB_INSTALLATION_TOKEN
  GB_OAUTH_TOKEN
  GB_TARGET_STATUS_OPTION_ID

Refresh validation additionally requires:
  GB_OAUTH_CLIENT_ID
  GB_OAUTH_REFRESH_TOKEN
  GB_OAUTH_CLIENT_SECRET          unless --device-flow is used`);
}

async function main() {
    const argumentsSet = new Set(process.argv.slice(2));
    if (argumentsSet.has("--help")) {
        printUsage();
        return;
    }
    const allowedArguments = new Set([
        "--device-flow",
        "--rotate-refresh-token",
        "--gh-control",
        "--gh-mapping",
        "--project-filter-probe",
    ]);
    const unknownArguments = [...argumentsSet].filter((argument) => !allowedArguments.has(argument));
    if (unknownArguments.length) {
        throw new ValidationError(`Unknown argument: ${unknownArguments[0]}`);
    }
    const boundaryModes = [
        "--gh-control",
        "--gh-mapping",
        "--project-filter-probe",
    ]
        .filter((argument) => argumentsSet.has(argument));
    if (boundaryModes.length > 1) {
        throw new ValidationError(`${boundaryModes.join(" and ")} cannot be used together`);
    }

    const [repositoryOwner, repositoryName, extraRepositoryPart] = requiredEnvironment("GB_REPOSITORY").split("/");
    if (!repositoryOwner || !repositoryName || extraRepositoryPart) {
        throw new ValidationError("GB_REPOSITORY must use owner/repository format");
    }
    const pullRequestNumber = positiveInteger("GB_PR_NUMBER");
    const projectOwner = requiredEnvironment("GB_PROJECT_OWNER");
    const projectNumber = positiveInteger("GB_PROJECT_NUMBER");
    const installationToken = process.env.GB_INSTALLATION_TOKEN?.trim() || await mintInstallationToken();
    let oauthToken;
    let deviceAuthorization;
    if (argumentsSet.has("--device-flow")) {
        deviceAuthorization = await oauthDeviceFlow();
        oauthToken = deviceAuthorization.accessToken;
    } else if (argumentsSet.has("--rotate-refresh-token")) {
        oauthToken = await rotateOAuthToken({
            clientID: requiredEnvironment("GB_OAUTH_CLIENT_ID"),
            clientSecret: requiredEnvironment("GB_OAUTH_CLIENT_SECRET"),
            refreshToken: requiredEnvironment("GB_OAUTH_REFRESH_TOKEN"),
        });
        console.log("✓ OAuth access/refresh token rotation succeeded");
    } else {
        oauthToken = requiredEnvironment("GB_OAUTH_TOKEN");
    }
    if (deviceAuthorization && argumentsSet.has("--rotate-refresh-token")) {
        oauthToken = await rotateOAuthToken({
            clientID: deviceAuthorization.clientID,
            refreshToken: deviceAuthorization.refreshToken,
        });
        console.log("✓ OAuth access/refresh token rotation succeeded");
    }

    const [oauthIdentity, closingIssueResult] = await Promise.all([
        loadOAuthIdentity(oauthToken),
        loadClosingIssues(
            installationToken,
            repositoryOwner,
            repositoryName,
            pullRequestNumber
        ),
    ]);
    if (oauthIdentity.nodeID !== closingIssueResult.repositoryOwner.id) {
        throw new ValidationError("OAuth user and private repository installation owner do not match");
    }
    if (oauthIdentity.login.toLowerCase() !== projectOwner.toLowerCase()) {
        throw new ValidationError("OAuth user does not own the configured personal Project");
    }
    console.log("✓ OAuth token has only the project scope");
    console.log("✓ OAuth identity matches the personal installation owner");
    console.log(`✓ Installation token found ${closingIssueResult.issues.length} closing Issue(s)`);

    const project = await loadProject(oauthToken, projectOwner, projectNumber);
    const closingIssueIDs = new Set(closingIssueResult.issues.map((issue) => issue.id));
    if (argumentsSet.has("--project-filter-probe")) {
        const controlItem = await findProjectItemWithGH(
            projectOwner,
            projectNumber,
            closingIssueIDs
        );
        if (!controlItem?.content?.id || !closingIssueIDs.has(controlItem.content.id)) {
            throw new ValidationError(
                "Local gh could not locate a closing Issue's personal Project item for the filter control"
            );
        }
        console.log("✓ Local gh supplied the expected Project item for filter comparison");

        const filter = `repo:${repositoryOwner}/${repositoryName} is:issue`;
        const items = await loadFilteredProjectItemsViaREST(
            oauthToken,
            projectOwner,
            projectNumber,
            filter
        );
        const classification = classifyFilteredItem(
            items,
            controlItem.id,
            controlItem.content.id,
            (item) => item.node_id,
            (item) => item.content?.node_id
        );
        console.log(
            `REST personal Project items q filter returned ${items.length} item(s); target is ${classification}`
        );
        console.log("REST project filter probe completed");
        return;
    }

    let item;
    if (argumentsSet.has("--gh-mapping")) {
        item = await findProjectItemWithGH(projectOwner, projectNumber, closingIssueIDs);
        if (!item) {
            throw new ValidationError("Local gh could not locate a closing Issue's personal Project item");
        }
        console.log("✓ Local gh supplied the Issue-to-Project-item mapping");
    } else {
        const oauthProjectItems = await loadProjectItems(oauthToken, projectOwner, projectNumber);
        item = oauthProjectItems.find(
            (candidate) => closingIssueIDs.has(candidate.content?.id)
        ) ?? null;
        let installationLookupError;
        if (!item) {
            let installationItemID;
            try {
                installationItemID = await findProjectItemViaInstallation(
                    installationToken,
                    closingIssueIDs,
                    new Set(oauthProjectItems.map((candidate) => candidate.id))
                );
            } catch (error) {
                installationLookupError = error;
            }
            if (installationItemID) {
                item = oauthProjectItems.find((candidate) => candidate.id === installationItemID);
                if (!item) {
                    throw new ValidationError(
                        "installation token found the Project item, but OAuth could not read it by item ID"
                    );
                }
                console.log("✓ Installation token located the private Issue's personal Project item");
                console.log("✓ OAuth project-only token read the known Project item by ID");
            }
        }
        if (!item && argumentsSet.has("--gh-control")) {
            const controlItem = await findProjectItemWithGH(projectOwner, projectNumber, closingIssueIDs);
            if (controlItem) {
                const installationDetail = installationLookupError instanceof Error
                    ? `; installation lookup failed: ${installationLookupError.message}`
                    : "";
                throw new ValidationError(
                    `neither minimal token could locate a Project item that the local gh repo+project token can see${installationDetail}`
                );
            }
            throw new ValidationError(
                "neither project-only OAuth nor the local gh token found the Issue in the configured Project"
            );
        }
        if (!item) {
            if (installationLookupError) throw installationLookupError;
            throw new ValidationError("Neither minimal token could locate the closing Issue's personal Project item");
        }
        if (!installationLookupError && item.content?.id) {
            console.log("✓ OAuth project-only token located the private Issue's personal Project item");
        }
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
    if (originalStatusOptionID === targetStatusOptionID) {
        throw new ValidationError("Target Status option must differ from the current Status option");
    }

    let mutationApplied = false;
    try {
        await updateStatus(
            oauthToken,
            project.id,
            item.id,
            project.statusField.id,
            targetStatusOptionID
        );
        mutationApplied = true;
        console.log("✓ OAuth project-only token updated the Project item Status");
    } finally {
        if (mutationApplied) {
            if (originalStatusOptionID) {
                await updateStatus(
                    oauthToken,
                    project.id,
                    item.id,
                    project.statusField.id,
                    originalStatusOptionID
                );
            } else {
                await clearStatus(oauthToken, project.id, item.id, project.statusField.id);
            }
            console.log("✓ Original Project item Status restored");
        }
    }

    if (argumentsSet.has("--gh-mapping")) {
        console.log("Boundary 1 known-item mutation validation passed");
    } else {
        console.log("Phase 0 personal authorization validation passed");
    }
}

main().catch((error) => {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`Validation failed: ${message}`);
    process.exitCode = 1;
});
