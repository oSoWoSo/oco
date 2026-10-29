# Codeberg PR webhook relay

This Worker receives Codeberg/Forgejo pull-request webhooks and dispatches the relevant events to GitHub Actions. Codeberg does not run a workflow for this integration.

## Deploy

Install Node.js and deploy from the repository root with Wrangler 4:

```sh
npx wrangler@4 deploy --config .github/webhook-relay/wrangler.toml
```

The deployment prints the Worker URL. Configure both secrets before enabling the Codeberg webhook:

```sh
npx wrangler@4 secret put FORGEJO_WEBHOOK_SECRET --config .github/webhook-relay/wrangler.toml
npx wrangler@4 secret put GITHUB_TOKEN --config .github/webhook-relay/wrangler.toml
```

Use a newly generated high-entropy value for `FORGEJO_WEBHOOK_SECRET`; enter the same value as the webhook Secret in Codeberg. `GITHUB_TOKEN` must be a GitHub token for `oSoWoSo/oco` with repository-dispatch permission (fine-grained token: **Contents: read and write**). Do not put either secret in the repository or Wrangler configuration file.

## Configure Codeberg

In the `oSoWoSo/oco` repository settings, add a Forgejo webhook:

- Target URL: the deployed Worker URL
- HTTP method: `POST`
- POST content type: `application/json`
- Secret: the value used for `FORGEJO_WEBHOOK_SECRET`
- Trigger: **Pull Request Events**
- Active: enabled

The Worker verifies `X-Forgejo-Signature` over the raw request body, accepts only `pull_request` events for the `OCO` base branch and actions `opened`, `reopened`, `synchronize`, or `edited`, and ignores mirrored `mirror/*` heads. It then sends only the action and PR number to the existing GitHub `repository_dispatch` workflow. Unsupported events are acknowledged without dispatching.

## Local test

Run from the repository root:

```sh
node --test .github/webhook-relay/test_worker.mjs
```
