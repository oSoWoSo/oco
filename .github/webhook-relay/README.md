# Codeberg webhook relay

This Cloudflare Worker receives Codeberg/Forgejo webhooks and dispatches the relevant events to GitHub Actions, so Codeberg does not need to run any CI for these integrations. The relay is how the OCO repository keeps its PR and branch state in sync between Codeberg and GitHub:

| Codeberg event | Worker dispatch | GitHub workflow |
|---|---|---|
| `pull_request` on `OCO` | `codeberg_pr` | `mirror-codeberg-pr.yml` → creates/updates the mirrored GitHub PR, and reflects merges/closes on closed events |
| `push` to `OCO` | `codeberg_push` | `sync-codeberg-to-github.yml` → fast-forwards GitHub `OCO` |

The reverse directions (GitHub → Codeberg) run natively on GitHub (`mirror-pr-to-codeberg.yml`, `toCB.yml`) and need no webhook.

## Deploy

The Worker is named `oco` and is configured by the `wrangler.toml` at the repository root, which points `main` at `.github/webhook-relay/worker.js`. Cloudflare Workers Builds runs from the repository root, so it picks up that file; a config inside this directory would be invisible to it.

For a manual deploy, install Node.js and run from the repository root:

```sh
npx wrangler@4 deploy
```

The deployment prints the Worker URL. Configure both secrets before enabling the Codeberg webhook:

```sh
npx wrangler@4 secret put FORGEJO_WEBHOOK_SECRET
npx wrangler@4 secret put GITHUB_TOKEN
```

Use a newly generated high-entropy value for `FORGEJO_WEBHOOK_SECRET`; enter the same value as the webhook Secret in Codeberg. `GITHUB_TOKEN` must be a GitHub token for `oSoWoSo/oco` with repository-dispatch permission (fine-grained token: **Contents: read and write**). Do not put either secret in the repository or Wrangler configuration file.

## Configure Codeberg

In the `oSoWoSo/oco` repository settings, add a Forgejo webhook:

- Target URL: the deployed Worker URL
- HTTP method: `POST`
- POST content type: `application/json`
- Secret: the value used for `FORGEJO_WEBHOOK_SECRET`
- Trigger: **Pull Request Events** and **Push Events**
- Active: enabled

The Worker verifies `X-Forgejo-Signature` over the raw request body. It accepts:

- **Push events** whose `ref` is `refs/heads/OCO`, dispatches `codeberg_push` with the new head SHA, and ignores branch creation/deletion and other refs.
- **Pull request events** for the `OCO` base branch with actions `opened`, `reopened`, `synchronize`, `synchronized`, `edited`, or `closed`, ignoring mirrored `mirror/*` heads, and dispatches `codeberg_pr` with only the action and PR number (mirror-pr normalizes Forgejo's `synchronized` to GitHub's `synchronize`, and resolves the merged state from the Codeberg API).

Unsupported events are acknowledged without dispatching.

## Local test

Run from the repository root:

```sh
node --test .github/webhook-relay/test_worker.mjs
```
