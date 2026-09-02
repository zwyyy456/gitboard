#!/usr/bin/env node

const graphqlURL = "https://api.github.com/graphql";
const apiVersion = "2026-03-10";

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

async function rotateOAuthToken() {
    const clientID = requiredEnvironment("GB_OAUTH_CLIENT_ID");
    const clientSecret = requiredEnvironment("GB_OAUTH_CLIENT_SECRET");
    const refreshToken = requiredEnvironment("GB_OAUTH_REFRESH_TOKEN");
    const response = await fetch("https://github.com/login/oauth/access_token", {
        method: "POST",
        headers: {
            Accept: "application/json",
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "GitBoard-authorization-validator",
        },
        body: new URLSearchParams({
            client_id: clientID,
            client_secret: clientSecret,
            grant_type: "refresh_token",
            refresh_token: refreshToken,
        }),
    });
    const body = await response.json().catch(() => null);
    if (!response.ok || !body?.access_token || !body?.refresh_token) {
        throw new ValidationError(`OAuth refresh failed: ${body?.error_description ?? body?.error ?? response.status}`);
    }
    if (!Number.isFinite(body.expires_in) || !Number.isFinite(body.refresh_token_expires_in)) {
        throw new ValidationError("OAuth refresh response did not contain token expiration values");
    }
    return body.access_token;
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
    const unexpectedRepositoryScope = ["repo", "public_repo"].find((scope) => scopes.has(scope));
    if (unexpectedRepositoryScope) {
        throw new ValidationError(`OAuth token has unexpected repository scope: ${unexpectedRepositoryScope}`);
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

async function findProjectItem(token, owner, projectNumber, issueIDs) {
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
        const item = items.nodes.find((candidate) => issueIDs.has(candidate.content?.id));
        if (item) return item;
        cursor = items.pageInfo.hasNextPage ? items.pageInfo.endCursor : null;
    } while (cursor);
    throw new ValidationError("OAuth token could not locate a closing Issue's personal Project item");
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
    console.log(`Usage: node Automation/scripts/validate-personal-auth.mjs [--rotate-refresh-token]

Required environment:
  GB_INSTALLATION_TOKEN
  GB_OAUTH_TOKEN                 unless --rotate-refresh-token is used
  GB_REPOSITORY                 owner/repository
  GB_PR_NUMBER
  GB_PROJECT_OWNER
  GB_PROJECT_NUMBER
  GB_TARGET_STATUS_OPTION_ID

Refresh validation additionally requires:
  GB_OAUTH_CLIENT_ID
  GB_OAUTH_CLIENT_SECRET
  GB_OAUTH_REFRESH_TOKEN`);
}

async function main() {
    const argumentsSet = new Set(process.argv.slice(2));
    if (argumentsSet.has("--help")) {
        printUsage();
        return;
    }
    const unknownArguments = [...argumentsSet].filter((argument) => argument !== "--rotate-refresh-token");
    if (unknownArguments.length) {
        throw new ValidationError(`Unknown argument: ${unknownArguments[0]}`);
    }

    const installationToken = requiredEnvironment("GB_INSTALLATION_TOKEN");
    let oauthToken;
    const [repositoryOwner, repositoryName, extraRepositoryPart] = requiredEnvironment("GB_REPOSITORY").split("/");
    if (!repositoryOwner || !repositoryName || extraRepositoryPart) {
        throw new ValidationError("GB_REPOSITORY must use owner/repository format");
    }
    const pullRequestNumber = positiveInteger("GB_PR_NUMBER");
    const projectOwner = requiredEnvironment("GB_PROJECT_OWNER");
    const projectNumber = positiveInteger("GB_PROJECT_NUMBER");
    const targetStatusOptionID = requiredEnvironment("GB_TARGET_STATUS_OPTION_ID");

    if (argumentsSet.has("--rotate-refresh-token")) {
        oauthToken = await rotateOAuthToken();
        console.log("✓ OAuth access/refresh token rotation succeeded");
    } else {
        oauthToken = requiredEnvironment("GB_OAUTH_TOKEN");
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
    console.log("✓ OAuth identity matches the personal installation owner");
    console.log(`✓ Installation token found ${closingIssueResult.issues.length} closing Issue(s)`);

    const project = await loadProject(oauthToken, projectOwner, projectNumber);
    const optionIDs = new Set(project.statusField.options.map((option) => option.id));
    if (!optionIDs.has(targetStatusOptionID)) {
        throw new ValidationError("GB_TARGET_STATUS_OPTION_ID is not an option in the Project Status field");
    }
    const item = await findProjectItem(
        oauthToken,
        projectOwner,
        projectNumber,
        new Set(closingIssueResult.issues.map((issue) => issue.id))
    );
    console.log("✓ OAuth project-only token located the private Issue's Project item");

    const originalStatusOptionID = item.fieldValueByName?.optionId ?? null;
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

    console.log("Phase 0 personal authorization validation passed");
}

main().catch((error) => {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`Validation failed: ${message}`);
    process.exitCode = 1;
});
