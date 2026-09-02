# GitBoard Automation

The automation service is implemented in stages. Before the Worker is built, the
personal-account authorization boundary must be verified against a real private
repository and personal Project.

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
