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
npm test
npm run test:integration
npm run build
```

The default test command runs fast Node unit tests. `test:integration` runs the
Worker in the local Cloudflare runtime with an isolated D1 database and applies
all migrations before exercising it.

Keep local and deployed secret values out of Wrangler variables. Local values
belong in the ignored `.dev.vars`; deployed values are configured as Worker
secrets. `wrangler.jsonc` declares every required secret so development and
deployment fail clearly when one is missing.

D1 migrations remain the only source of schema changes.

GitHub App webhooks are accepted at `POST /webhooks/github`. The receiver
verifies `X-Hub-Signature-256` before decoding, ignores unrelated events and
actions, persists only the identifiers needed to recompute current truth, and
places only the delivery ID on the Queue. The D1 delivery row is both the
deduplication record and outbox; the scheduled handler retries delivery rows
that have not reached the Queue. Complete webhook payloads are neither queued
nor stored.

The same signed endpoint handles GitHub App installation lifecycle events.
Lifecycle events use the same outbox and are acknowledged before any GitHub API
request. The consumer uses a short-lived RS256 App JWT and an ephemeral
installation token to reconcile the installation's current status and complete
repository set, so event delivery order does not become state truth. Suspension,
deletion, or source repository removal disables the affected automation.
Neither token is written to D1 or logs.

For each queued pull request, `RepositoryTruthReader` uses an installation token
to reload every currently visible closing Issue and every closing pull request
for those Issues, including closed pull requests. Both connections are fully
paginated. Repositories are queried and authorized by opaque GitHub node ID;
names are retained only for display.

`WorkflowReducer` is a pure function. Its priority is merged → open ready → open
draft → all closed-unmerged; a closed Issue without a merged closing pull request
and an Issue without closing pull requests are left unchanged.

`OAuthCredentialProvider` is the only runtime boundary that decrypts personal
Project OAuth tokens. It refreshes near-expiry tokens, checks the refreshed
identity and actual `project` scope, saves each replacement token pair with an
optimistic credential version, and performs one refresh/retry after a 401.
Tokens use versioned AES-GCM envelopes and are never included in errors.

`PersonalProjectGateway` groups assignments by the Issue repository and uses the
versioned personal Project REST endpoint with `repo:OWNER/REPOSITORY is:issue`.
It follows every Link page and matches only exact `content.node_id` values. An
unresolved scan with any item lacking `item.node_id` or `content.node_id` fails
as visibility-indeterminate; only a complete, fully identifiable scan yields
`NOT_IN_PROJECT`. Project response content is reduced to those two node IDs.

Status updates use only `updateProjectV2ItemFieldValue` with the Project, REST
item `node_id`, Status field, and option IDs. A node-resolution failure triggers
one fresh REST lookup: a missing item becomes `NOT_IN_PROJECT`, while a new item
ID is retried once. There is no REST PATCH writer and no unbounded retry.

The Queue consumer runs with one global concurrent invocation and processes each
batch sequentially. Every attempt reloads repository truth; completed or failed
or ignored delivery IDs are acknowledged without another GitHub call. Stable
failures are recorded and acknowledged, while network, rate-limit, and 5xx
failures are retried with a bounded delay. The same Worker consumes the dead
letter queue and marks every exhausted nonterminal delivery failed without
overwriting a terminal result. Status writes remain idempotent across
redelivery.

Daily maintenance marks delivery work that has made no progress for seven days
as `DELIVERY_STALE`, removes terminal deliveries after 30 days, and reclaims
setup sessions one day after expiry together with OAuth and installation data
that no automation or remaining setup session still references.

## Production release

Use a dedicated GitHub App, OAuth App, private test repository, and personal
Project. Do not reuse production user data for the release probes below.

### 1. Register GitHub applications

Choose the Worker's final HTTPS origin before registration. The OAuth App
callback URL is:

```text
https://WORKER_ORIGIN/oauth/callback
```

The GitHub App uses these URLs:

```text
Setup URL:   https://WORKER_ORIGIN/setup/github-app
Webhook URL: https://WORKER_ORIGIN/webhooks/github
```

Grant the GitHub App only repository Metadata read, Issues read, and Pull
requests read. Subscribe it to pull request, installation, and installation
repositories events. Keep the webhook inactive until the Worker is deployed.
The separate OAuth App must request `project offline_access`; the Worker rejects
an authorization whose effective ordinary scope does not include `project`.

### 2. Prepare release configuration

Copy `.dev.vars.example` to the ignored `.dev.vars.production`, replace every
value, and keep the file outside source control. `PUBLIC_BASE_URL` is the HTTPS
origin with no path. Generate independent high-entropy values for the webhook
secret and the 32-byte OAuth encryption key, for example:

```bash
openssl rand -hex 32
openssl rand -base64 32
```

Validate names and formats without printing secret values. `config:check`
automatically loads `.dev.vars.production` when it exists:

```bash
cd Automation
npm run config:check
```

### 3. Provision Cloudflare resources

The production D1 database and both Queues are already provisioned, and
`wrangler.jsonc` contains the database binding. Authenticate Wrangler and verify
that the configured resources are visible before release:

```bash
cd Automation
npx wrangler login
npx wrangler whoami
npx wrangler d1 info gitboard-automation
npx wrangler queues list
```

Apply the schema before serving setup or webhook traffic. Cloudflare records a
backup when applying remote D1 migrations:

```bash
npx wrangler d1 migrations apply gitboard-automation --remote
```

Run the complete local release check, deploy the secrets and code together, and
verify the unauthenticated health endpoint:

```bash
npm run release:check
npx wrangler deploy --secrets-file .dev.vars.production
curl --fail --silent --show-error https://WORKER_ORIGIN/health
```

The expected health response is `{"status":"ok"}`. Enable the GitHub App
webhook only after this succeeds. Build the release app with
`GITBOARD_AUTOMATION_BASE_URL` set to the same origin; an empty setting
deliberately makes Automation unavailable rather than selecting an implicit
server.

Cloudflare's current command references cover
[D1 resource and migration commands](https://developers.cloudflare.com/d1/wrangler-commands/),
[Queue creation](https://developers.cloudflare.com/queues/get-started/), and
[deploying a dotenv secrets file](https://developers.cloudflare.com/workers/configuration/secrets/).

### 4. Release gates

All gates use disposable data and must finish without a complete GitHub payload
or credential appearing in logs. A mutation gate is complete only after the
original Status is restored.

| Gate | Disposable setup and action | Required result |
| --- | --- | --- |
| Repository narrowing | Link at least two Issues from different installed repositories to multiple Project items, then deliver a pull request event for one repository | Only exact Issue node IDs from the event's repository are selected and updated |
| REST pagination | Place the target private Issue after the first Project item page and trigger its pull request | The Link chain is fully followed and the target item is found |
| REST-to-GraphQL identity | Run `validate-personal-auth.mjs --device-flow --gh-mapping` | REST `item.node_id` is accepted by the status mutation and the original Status is restored |
| Refresh path | Add `--rotate-refresh-token` to the personal validator | Refresh succeeds, the REST lookup and mutation succeed, and the original Status is restored |
| OAuth loss | Revoke the disposable OAuth authorization or remove its `project` grant, then trigger a delivery and refresh Automation settings | No mutation occurs; health reports reauthorization or missing scope with a stable delivery error |
| Invalid selection | Submit a setup selection with an unknown Status field or option ID | Setup rejects it and no automation row is created |
| Repository removal | Remove the configured repository from the disposable GitHub App installation, then wait for `installation_repositories` delivery | The repository is reconciled out of D1 and its automation is disabled before another mutation |

The deterministic suite covers reducer priority, cross-repository grouping,
REST Link pagination, exact node matching, opaque item rejection, one 401
refresh, missing scope, rate-limited 403, and deleted Project items. Those tests
do not replace the real private-repository gates.

After all gates pass, perform one setup from the release GitBoard build and
confirm settings can pause, resume, reauthorize, and delete its automation.
Deleting must remove the automation from the management response; shared user,
installation, and credential rows are retained only while another automation
uses them.

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

### REST project-filter boundary

The runtime narrows personal Project items with
`GET /users/{owner}/projectsV2/{number}/items?q=...`. This read-only probe checks
that the filter exposes the expected private Issue item to the project-only
OAuth token.

The request uses `repo:OWNER/REPOSITORY is:issue`, derived from
`GB_REPOSITORY`. The local `gh` token first supplies the expected item and
content IDs strictly as a control. Run:

```bash
node Automation/scripts/validate-personal-auth.mjs \
  --device-flow \
  --project-filter-probe
```

The result reports only the filtered item count and one of these target
classifications:

- `complete`: the expected item and its private Issue content ID were returned.
- `redacted`: the expected item ID was returned but its private content ID was
  hidden.
- `missing`: the expected item ID was not returned by the filter.

Success ends with `REST project filter probe completed`. An API authorization
or schema error is reported without printing the token or response payload.

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
