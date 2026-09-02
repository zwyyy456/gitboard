# GitBoard Automation

The automation service is a Cloudflare Worker backed by D1. It uses a GitHub App
to read repository truth and a separate OAuth App to update a personal Project.

## Worker development

Install the pinned toolchain and validate the local schema from `Automation/`:

```bash
npm install
cp .dev.vars.example .dev.vars
npm run db:migrate:local
npm run typecheck
npm run build
```

Keep local and deployed secret values out of Wrangler variables. Local values
belong in the ignored `.dev.vars`; deployed values are configured as Worker
secrets. `wrangler.jsonc` declares every required secret so development and
deployment fail clearly when one is missing.

The D1 binding intentionally omits a checked-in database ID. Current Wrangler
can provision the resource on first deployment and write the assigned ID back
to the configuration. Review that generated change before committing it. D1
migrations remain the only source of schema changes.

GitHub App webhooks are accepted at `POST /webhooks/github`. The receiver
verifies `X-Hub-Signature-256` before decoding, ignores unrelated events and
actions, and places only delivery, installation, repository, pull request, and
action identifiers on the Queue. The D1 delivery row is the deduplication
record; complete webhook payloads are neither queued nor stored.

The same signed endpoint handles GitHub App installation lifecycle events.
Installation authentication uses a short-lived RS256 App JWT and an ephemeral
installation token. Repository access is reconciled from GitHub into D1;
suspension, deletion, or source repository removal disables the affected
automation. Neither token is written to D1 or logs.

For each queued pull request, `RepositoryTruthReader` uses an installation token
to reload every currently visible closing Issue and every closing pull request
for those Issues, including closed pull requests. Both connections are fully
paginated. Cross-repository Issues are accepted only when their numeric
repository ID is present in the same installation's D1 repository set.

## Authorization boundary validation

Before deployment, the personal-account authorization boundary must be verified
against a real private repository and personal Project.

## Phase 0: personal authorization validation

Create disposable validation data first:

1. A private repository owned by your personal account.
2. A personal Project with a Status field containing at least two options.
3. An open Issue from that repository added to the Project.
4. A pull request targeting the default branch whose description formally
   closes the Issue, for example `Fixes #1`.

Create a GitHub App with only these repository permissions:

- Metadata: Read
- Pull requests: Read
- Issues: Read

GitHub's setup references are [registering a GitHub App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app)
and [generating an installation token](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app).

Webhooks can remain disabled during phase 0. Install the App on your personal
account and grant it access only to the disposable private repository. Generate
a private key, and note the App ID plus the numeric installation ID from the
installation settings URL.

Create a separate OAuth App, enable Device Flow in its settings, and note its
Client ID. The validator requests only `project offline_access`; it rejects any
ordinary OAuth scope other than `project`.
[OAuth web/device flow](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps)
documents both the device authorization and refresh-token behavior.

Run the recommended flow from the repository root:

```bash
export GB_GITHUB_APP_ID=123456
export GB_INSTALLATION_ID=12345678
export GB_GITHUB_APP_PRIVATE_KEY_PATH="/absolute/path/to/test-app.private-key.pem"
export GB_OAUTH_CLIENT_ID=Ov23liExample
export GB_REPOSITORY=owner/repository
export GB_PR_NUMBER=123
export GB_PROJECT_OWNER=owner
export GB_PROJECT_NUMBER=1

node Automation/scripts/validate-personal-auth.mjs \
  --device-flow \
  --rotate-refresh-token \
  --gh-control
```

The script prints GitHub's device verification URL and a one-time user code.
Approve it in the browser. It then creates both tokens in memory, validates the
cross-token GraphQL path, changes the item to another Status option, restores the
original Status, and discards the tokens. It first tries the OAuth-side lookup;
if private content is hidden, it tries the complementary path where the
installation token resolves Issue to Project item and OAuth reads that known
item ID. If both minimal-token paths fail, `--gh-control` uses the locally
authenticated `gh` token for a read-only comparison. The token remains in memory
and is never printed or uploaded.

### Known-item mutation boundary

The local-mapping design has one separate boundary to validate: whether the
project-only OAuth token can update a private repository's Project item when the
item ID is already known. Run the same disposable setup with:

```bash
node Automation/scripts/validate-personal-auth.mjs \
  --device-flow \
  --gh-mapping
```

In this mode, the locally authenticated `gh` token only resolves the closing
Issue to its Project item ID and reads the original Status. The script then uses
the OAuth token, whose ordinary scopes must contain only `project`, to change
the known item and restore its original Status. It deliberately skips both
minimal-token association lookups so a successful mutation proves this boundary
directly. Neither token nor the complete Project payload is printed or uploaded.

Success ends with `Boundary 1 known-item mutation validation passed`. A GraphQL
authorization or node-resolution error at the mutation step means a known item
ID is insufficient for project-only OAuth and the local-mapping design cannot be
used for that private item.

### Add-existing-item resolution boundary

The preferred Worker design has one additional boundary to validate: whether a
project-only OAuth token can pass a private repository Issue node ID to
`addProjectV2ItemById` and receive the ID of the Project item that already
contains that Issue.

Use the same disposable setup. The Issue must already be present in the
configured Project, and the locally authenticated `gh` token must be able to
read both the private repository and the personal Project. Run:

```bash
node Automation/scripts/validate-personal-auth.mjs \
  --device-flow \
  --add-item-probe
```

Before calling the mutation, the script uses the local `gh` token for a
read-only preflight that confirms a closing Issue already exists in the Project
and records its existing item ID. If that preflight fails, the script stops and
does not call `addProjectV2ItemById`, preventing the probe from adding a missing
Issue. The mutation runs only with the project-only OAuth token. Its returned ID
must equal the existing ID recorded by `gh`; the script then changes the item's
Status and restores the original value.

Success ends with `Boundary 2 add-item resolution validation passed`. A GraphQL
authorization or node-resolution error from `addProjectV2ItemById` means the
project-only OAuth token cannot use the private Issue node ID to resolve the
existing Project item. Tokens and complete GitHub responses are never printed
or persisted.

### Project-side filter boundaries

If both minimal-token association lookups and the add-item resolution boundary
fail, test whether server-side Project filtering exposes the existing private
Issue item. This mode makes two read-only requests with the project-only OAuth
token:

- GraphQL `ProjectV2.items(query:)`
- REST `GET /users/{owner}/projectsV2/{number}/items?q=...`

Both requests use `repo:OWNER/REPOSITORY is:issue`, derived from
`GB_REPOSITORY`. The local `gh` token first supplies the expected item and
content IDs strictly as a control. Run:

```bash
node Automation/scripts/validate-personal-auth.mjs \
  --device-flow \
  --project-filter-probe
```

Each result reports only the filtered item count and one of these target
classifications:

- `complete`: the expected item and its private Issue content ID were returned.
- `redacted`: the expected item ID was returned but its private content ID was
  hidden.
- `missing`: the expected item ID was not returned by the filter.

Success ends with `Boundary 3 project-side filter probes completed`. This means
both API requests completed; the classifications determine whether either path
is usable. An API authorization or schema error is reported without printing
the token or response payload.

For an already-issued token pair, the direct-token form remains available:

```bash
GB_INSTALLATION_TOKEN=... \
GB_OAUTH_TOKEN=... \
GB_REPOSITORY=owner/repository \
GB_PR_NUMBER=123 \
GB_PROJECT_OWNER=owner \
GB_PROJECT_NUMBER=1 \
node Automation/scripts/validate-personal-auth.mjs
```

`GB_TARGET_STATUS_OPTION_ID` is optional. When omitted, the validator chooses a
Status option different from the Issue's current value.

To include refresh-token rotation, use a disposable OAuth authorization. Replace
`GB_OAUTH_TOKEN` in the command above with these values and add the flag:

```bash
GB_OAUTH_CLIENT_ID=... \
GB_OAUTH_CLIENT_SECRET=... \
GB_OAUTH_REFRESH_TOKEN=... \
node Automation/scripts/validate-personal-auth.mjs --rotate-refresh-token
```

Refreshing consumes the supplied access/refresh token pair. The replacement
tokens remain in memory only and are discarded when validation finishes. The
script never prints token values or complete GitHub responses.

## Phase 0B: organization boundary validation

An organization Project can contain an Issue from a private repository owned by
a personal account. Project item changes are delivered through an organization
webhook, not the GitHub App's own webhook. Configure the organization webhook
for `Projects V2 item`, then record these non-secret values from one delivery:

- `projects_v2_item.project_node_id`
- `projects_v2_item.node_id`
- `projects_v2_item.content_node_id`

Install the same GitHub App on the organization with the organization `Projects`
permission set to read and write. Run the boundary validator with the
organization installation ID and the webhook IDs:

```bash
export GB_GITHUB_APP_ID=123456
export GB_ORGANIZATION_INSTALLATION_ID=12345678
export GB_GITHUB_APP_PRIVATE_KEY_PATH="/absolute/path/to/test-app.private-key.pem"
export GB_ORGANIZATION=organization
export GB_PROJECT_NUMBER=1
export GB_PROJECT_NODE_ID=PVT_example
export GB_PROJECT_ITEM_NODE_ID=PVTI_example
export GB_CONTENT_NODE_ID=I_example

node Automation/scripts/validate-organization-auth.mjs
```

The script creates the organization installation token in memory, scans every
item in the Project, and compares the webhook IDs with the scan. If that scan
hides the personal private Issue, the locally authenticated `gh` token supplies
the known mapping and original Status without printing or persisting its token.
The script then changes the known item's Status with the organization
installation token and restores the original value before exiting.
`GB_TARGET_STATUS_OPTION_ID` can select the temporary Status; otherwise the
script chooses a different option.

The final line states whether the organization scan exposed the personal private
Issue's content node ID. If it did, the Worker can initialize the mapping from a
full Project scan. If the Project item was visible but its content was hidden,
desktop mapping initialization is required. Tokens and complete GitHub responses
are never printed or persisted.
