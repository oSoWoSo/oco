# CI map

Workflows in `workflows/` are maintained directly. There is no `src/*.yml.in`
workflow generator. `./ocoman -u` updates repository metadata, not workflows.

## Repository layout and website boundary

`src/` is retired. Files are grouped by purpose:

```text
website/public/      Static public assets (CSS, JavaScript, icons, testing guide)
website/templates/   Site templates and fragments; never uploaded
config/              Autobump packs/dependencies/blacklist, feeds, OSV identities
lib/                 Shared shell libraries, signing-key handling, asset allowlist
tools/autobump/      Batch planning, version helpers, PR artifact validation/merge
tools/build/         Build loop and XBPS result collection
tools/repository/    Repodata utilities and publication manifest contract
tools/updates/       Feed issue handling, issue closing, version detection
tools/website/       Manual and published-feed generation
tools/community/     Community repository comparison
.github/scripts/     CI event adapters and orchestration helpers (no ci/ nesting)
.github/workflows/   GitHub workflow definitions
```

`lib/website.sh` defines the explicit public-file allowlist. Site builds stage
only these static files from `website/public/`, then generate the index, manual,
and architecture pages. Root asset uploads enumerate the allowlist plus generated
public documents; they never glob the source tree or even every file in `docs/`.
This also prevents stale scripts/config already present in a local `docs/`
directory from being uploaded again. Website templates are not public assets.
Production/testing publication prefixes are unchanged.

Existing unwanted files on the remote host are **not automatically deleted** by
this layout migration. Removing those needs a separately reviewed cleanup list;
package repositories, signing metadata, and legitimate site/feed files must be
preserved. Local runtime upstream state now lives under `.cache/oco/`.

## Package lifecycle

```text
feed-update / scan -> package-update issue -> bump -> autobump PR
                                                     |
                                      build: detect -> lint + build matrix
                                                     |
                                               shared build gate
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
provenance for the trusted release workflow. One always-running `🏗️ build gate`
checks detection, testing-base synchronization, lint, and all architecture builds
for PRs, pushes, and dispatches. It rejects skipped/missing required builds.
Autobump PRs additionally require nonempty packages and no removals. Only eligible
same-repository OCO autobump PRs produce the release plan after verification.
Ordinary publication depends on this same gate; there is no separate verification
job. Its existing `🏗️ build gate` check name is preserved.

`sync-testing` is intentionally skipped outside testing-targeted builds. All
jobs in the ordinary publication chain use `!cancelled()` plus explicit successful
dependency results. Without a status function, GitHub's implicit `success()` can
skip publication because of that skipped ancestor even after verification passes.
Do not remove these guards or replace them with unqualified `always()` writes.

### Binary dependency reuse on testing

The builder image already enables the production OCO binary repository. Before
lint/build, `build-repositories.sh` additionally configures xbps-src as follows:

- Builds from `refs/heads/testing`, including manual dispatch, and PRs targeting
  `testing`: **testing binaries first, then existing production/Void fallbacks**.
- OCO builds and PRs targeting OCO: production/Void only. Dispatching an OCO
  build with a testing **upload destination** does not enable testing dependencies.
- Other branches: production/Void only; publishing a feature branch to testing
  does not make it a canonical testing source.

Both bootstrap/host and cross-target architecture configurations are updated,
including glibc/musl and optional per-architecture overrides. Local binary
repositories retain their existing higher priority. The CI host's `/etc/xbps.d`
is not changed, so build-tool updates do not pull from testing. Testing uses the
same signing keys already provided by the builder image for production.

This enables xbps-src's normal reuse of compatible **binary dependencies**; it
does not skip compiling requested source targets, bypass checks, or reuse PR
workflow artifacts. Missing/incompatible binaries fall back to the usual
xbps-src dependency handling. No changes to publication routing are involved.

### Why an autobump OCO run skips publishing

`autobump-release.yml` verifies the successful PR run, validates the artifacts,
merges the exact tested PR revision, and publishes those verified binaries.
The resulting OCO push still rebuilds and verifies the merged source, but does
**not** publish a second time. Its detect summary explains this delegation and
links to the release workflow and source PR build. Release run titles identify
the source build run ID. Check the release run, not the skipped OCO publish job,
for the actual publication result.

### One publication contract and writer

All request producers use `tools/repository/surfer-publish.py --create` to write and validate
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

This refactor retains `ocoman`/`bump.sh`, forge credentials, and existing package
management features. File locations are now grouped as documented above. Real
XBPS builds and remote publication still need CI verification after deployment;
local fixture tests do not substitute for those integration checks.
