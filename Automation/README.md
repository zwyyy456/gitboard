# GitBoard Automation

The automation service is implemented in stages. Before the Worker is built, the
personal-account authorization boundary must be verified against a real private
repository and personal Project.

## Phase 0: personal authorization validation

Create a disposable private repository, a personal Project, and a pull request
that formally closes an Issue in that Project. Configure the GitHub App with
only these repository permissions:

- Metadata: Read
- Pull requests: Read
- Issues: Read

Authorize the separate OAuth App with `project offline_access`. Then run:

```bash
GB_INSTALLATION_TOKEN=... \
GB_OAUTH_TOKEN=... \
GB_REPOSITORY=owner/repository \
GB_PR_NUMBER=123 \
GB_PROJECT_OWNER=owner \
GB_PROJECT_NUMBER=1 \
GB_TARGET_STATUS_OPTION_ID=... \
node Automation/scripts/validate-personal-auth.mjs
```

`GB_TARGET_STATUS_OPTION_ID` must identify a Status option different from the
Issue's current option. The script changes the item to that option and restores
its original value before exiting.

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
