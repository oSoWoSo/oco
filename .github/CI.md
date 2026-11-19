# CI map

Workflows in `workflows/` are maintained directly. There is no `src/*.yml.in`
workflow generator. `./ocoman -u` updates repository metadata, not workflows.

## Package lifecycle

```text
feed-update / scan -> package-update issue -> bump -> autobump PR
                                                     |
                                      build: detect -> lint + build matrix
                                                     |
                                               build gate + status
                                                     |
                  OCO autobump: autobump-release -> validate -> merge
                                                     |
                                          publication request -> write-surfer
                                                     |
                                              close resolved issues

ordinary push / manual build -> same build matrix -> status -> publication request
                                                               |
                                                          write-surfer
```

`build.yml` uses **one architecture matrix job** for PRs, pushes, and dispatches.
PRs check out their exact head SHA and never invoke the publication writer.
Same-repository OCO autobump PRs additionally upload binaries with checksums and
provenance for the trusted release workflow. The release gate keeps its existing
`🏗️ build gate` check name; `Verify build result` rejects skipped/missing builds.
Ordinary publication also requires successful lint and build verification.

### Why an autobump OCO run skips publishing

`autobump-release.yml` verifies the successful PR run, validates the artifacts,
merges the exact tested PR revision, and publishes those verified binaries.
The resulting OCO push still rebuilds and verifies the merged source, but does
**not** publish a second time. Its detect summary explains this delegation and
links to the release workflow and source PR build. Release run titles identify
the source build run ID. Check the release run, not the skipped OCO publish job,
for the actual publication result.

### One publication contract and writer

All request producers use `src/surfer-publish.py --create` to write and validate
the same `surfer-publication` manifest:

- build: staged binaries, per-architecture results, optional removals;
- autobump release: verified PR binaries and results, merged source SHA;
- cleanup: named purges or automatic orphan reconciliation;
- metadata update: main-index refresh only.

`write-surfer.yml` is the **only remote package/site writer** used by these
workflows. It checks destination/ref restrictions, validates the request before
checking out its source, validates again against that source, and serializes
writes per destination with `concurrency.queue: max`. Do not replace this with
ordinary single-pending concurrency: that can discard pending publications.

Production remains restricted to trusted OCO runs. Testing publications from
sparse feature branches skip canonical orphan pruning. Removal-only requests
do not request feed updates, because there are no build results to feed.

## Workflow inventory

| Workflow | Responsibility / reason for separation |
|---|---|
| `build.yml` | Detect, lint, compile, gate, and publish ordinary builds |
| `bump.yml` | The only bumper entry point: single package, issue, and group operations |
| `autobump-release.yml` | Trusted `workflow_run` boundary for PR artifact validation, merge, and release |
| `testing-merge.yml` | Trusted completion hook for testing-targeted autobump PRs; no production release |
| `sync-testing.yml` | Reusable testing-base rebase; failure blocks dependent lint/build jobs |
| `write-surfer.yml` | Reusable serialized publication writer |
| `cleanup.yml` | Manual/reusable purge request; delegates writes to `write-surfer` |
| `update.yml` | Regenerate metadata and request main-index refresh |
| `tooling.yml` | Helper tests, symlink lint, JavaScript syntax, workflow syntax; also manually runnable |
| `check-workflows.yml` | Scheduled/manual external action **version** audit (not workflow syntax lint) |
| `feed-update.yml` | Scheduled feed-driven update issues and repair of existing issues |
| `scan.yml` | Manual direct upstream version scan; separate update source, shared issue lifecycle |
| `vur-check.yml` | External VUR CI integration, independent of local XBPS matrix |
| `mirror.yml` | Both PR mirror directions and build-result reporting; event-specific jobs/permissions |
| `sync.yml` | Outbound branch mirrors, with independent host retries/concurrency |
| `sync-codeberg-to-github.yml` | Inbound Codeberg push/manual fast-forward, with explicit force opt-in |

PR mirror jobs only check out trusted default/base revisions, never PR heads.
The webhook relay still dispatches `codeberg_pr` and `codeberg_push`; no webhook
or secret migration is needed. Consolidation must not broaden the permissions
of `pull_request_target` or execute PR scripts with forge/publishing tokens.

Removed: the deprecated `autobump.yml`, disabled `build-void.yml_`, standalone
symlink-lint workflow, and three separate PR-mirror/status wrappers. Their active
responsibilities live in `bump.yml`, `tooling.yml`, and `mirror.yml` respectively.

## Local validation

```sh
python3 -m venv /tmp/oco-tests
/tmp/oco-tests/bin/pip install -r tests/requirements.txt
# Install the zstd CLI with your system package manager too.
PATH="/tmp/oco-tests/bin:$PATH" sh tests/run.sh

actionlint -shellcheck= -pyflakes=
```

Tooling CI runs the same tests and pinned actionlint 1.7.12. The actionlint
configuration narrowly ignores its unsupported `concurrency.queue` diagnostic
in the three queued writer/merge workflows, not other syntax errors. Remove the
exception when actionlint supports the GitHub feature.

## Using `PROPOSAL/`

The proposal is an older architectural reference, **not a drop-in replacement**.
Adopt its useful principles: thin event adapters, one build path, shared domain
logic that can be tested locally, explicit trust boundaries, and one writer.

Do not silently import its behavior removals: it replaces issue/PR autobumps,
drops feeds/OSV/issue closing and other features, changes forge synchronization
to polling, prunes branches, and changes publication/index repair. In particular,
automatic deletion of `autobump/*` conflicts with the current repository rules.
Those are separate migrations requiring explicit decisions and integration tests,
not prerequisites for deduplicating the existing CI.

This refactor does not replace `ocoman`/`bump.sh`, move templates/assets/config,
change forge credentials, or remove existing package-management features. Real
XBPS builds and remote publication still need CI verification after deployment;
local fixture tests do not substitute for those integration checks.
