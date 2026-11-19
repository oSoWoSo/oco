# CI guide

Workflow definitions live in `.github/workflows/`. Edit them directly.
`./ocoman -u` updates repository metadata and the package list.

## Repository layout

| Directory | Contents |
|---|---|
| `.github/workflows/` | GitHub Actions workflows |
| `.github/scripts/` | CI event handling and orchestration |
| `tools/autobump/` | Update planning, version helpers, release validation and merging |
| `tools/build/` | Package builds and XBPS result collection |
| `tools/repository/` | Repository metadata and publication manifests |
| `tools/updates/` | Feed handling, update issues and version detection |
| `tools/website/` | Manual and published-feed generation |
| `tools/community/` | Community repository comparison |
| `lib/` | Shared shell helpers, signing-key handling and website asset allowlist |
| `config/` | Package groups, dependency manifests, blacklists, feeds and OSV identities |
| `website/public/` | Static website assets |
| `website/templates/` | Site-generation templates and fragments |

Local upstream-check state lives in `.cache/oco/`.

## Package updates and builds

1. `feed-update.yml` and `scan.yml` open package-update issues.
2. `bump.yml` plans updates and opens package PRs against `OCO` or `testing`.
3. `build.yml` detects affected packages, lints templates and runs the architecture matrix.
4. The `🏗️ build gate` checks detection, testing-base synchronization, lint and build results.
5. Successful builds can produce a publication request for `write-surfer.yml`.

The bumper creates package commits in a temporary Git worktree using the target
base's metadata layout. Its workflow checkout stays available to subsequent
steps. The temporary worktree is cleaned up on both success and failure.

PR builds use the exact PR head SHA and never invoke the publication writer.
Same-repository OCO autobump PRs also produce binaries, checksums and provenance
for `autobump-release.yml`. These PRs must contain packages and must not remove
packages. Only eligible PRs produce a release plan.

`autobump-release.yml` validates the successful PR build and its artifacts,
merges the tested revision and requests publication of the verified binaries.
The resulting OCO push verifies the merged source but delegates publication to
that release run. The build summary links to the release and source PR build.
Check the release run for the publication result.

Testing-targeted autobump PRs are handled by `testing-merge.yml` without a
production release. `sync-testing.yml` synchronizes their base before building.

### Binary dependencies

Builds from `refs/heads/testing` and PRs targeting `testing` prefer testing binary
dependencies, followed by production OCO and Void repositories. Other builds use
production OCO and Void repositories.

`build-repositories.sh` configures bootstrap/host and cross-target XBPS
repositories, including glibc/musl variants. Local binary repositories retain
higher priority. The CI host's `/etc/xbps.d` is not changed.

Requested package targets still compile and run checks. Missing or incompatible
binary dependencies use normal xbps-src dependency handling. The dependency
channel follows the source branch or PR base, not the publication destination.

## Publication

Production and testing are separate destinations:

- Production: `https://repo.osowoso.org/<architecture>/`
- Testing: `https://repo.osowoso.org/testing/<architecture>/`

All request producers use `tools/repository/surfer-publish.py --create` to create
and validate a `surfer-publication` manifest. Requests can contain package
binaries and results, package removals, or site-update instructions.

`write-surfer.yml` is the shared remote writer. It checks destination and source
restrictions, validates the request before and after checking out its source,
and queues writes per destination with `concurrency.queue: max`. Preserve this
queue so pending publications cannot be discarded.

Production requires a trusted OCO source. Testing publications from sparse
feature branches do not prune canonical packages. Removal-only requests do not
update the build feed.

The ordinary publication chain uses `!cancelled()` and explicit successful
dependency results. Keep these conditions: `sync-testing` is intentionally
skipped outside testing-targeted builds, and GitHub's implicit `success()` can
otherwise skip dependent publication jobs. Publication requires a successful
build gate.

### Website files

`lib/website.sh` allows these static files for staging and root website uploads:
`favicon.ico`, `main.js`, `manual.css`, `manual.js`, `style.css` and `testing.html`.
The site builder adds `index.html`, `manual.html`, `Manual.md` and architecture
pages. Package publication updates `feed.xml` as requested by the manifest.

Scripts, configuration, signing secrets, generation templates and development
documentation are not website payloads. Neither the source tree nor `docs/` is
uploaded as a directory. Remote cleanup requires an explicit review of paths;
package repositories, signing metadata and public documents must be preserved.

## Workflows

| Workflow | Responsibility |
|---|---|
| `build.yml` | Detect, lint, compile, gate and request publication |
| `bump.yml` | Package, issue and group update PRs |
| `autobump-release.yml` | Validate PR artifacts, merge and release |
| `testing-merge.yml` | Merge successful testing-targeted autobump PRs |
| `sync-testing.yml` | Synchronize testing bases before lint/build |
| `write-surfer.yml` | Serialized package and website publication |
| `cleanup.yml` | Request named purges or orphan reconciliation |
| `update.yml` | Regenerate metadata and request a main-index refresh |
| `tooling.yml` | Helper tests, symlink lint, JavaScript and workflow syntax checks |
| `check-workflows.yml` | Audit external action versions |
| `feed-update.yml` | Create and maintain feed-driven update issues |
| `scan.yml` | Check upstream versions directly |
| `vur-check.yml` | External VUR CI integration |
| `mirror.yml` | PR mirroring and build-result reporting |
| `sync.yml` | Outbound branch mirrors |
| `sync-codeberg-to-github.yml` | Inbound fast-forward synchronization with explicit force opt-in |

PR mirror jobs check out trusted default/base revisions, not PR heads. The
webhook relay dispatches `codeberg_pr` and `codeberg_push` events. Never execute
PR-controlled scripts with forge or publishing tokens. Automatic deletion of
`autobump/*` branches is prohibited by repository rules.

## Local validation

Install the `zstd` and `bats` command-line tools, then run:

```sh
python3 -m venv /tmp/oco-tests
/tmp/oco-tests/bin/pip install -r tests/requirements.txt
PATH="/tmp/oco-tests/bin:$PATH" sh tests/run.sh

actionlint -shellcheck= -pyflakes=
```

The test runner includes shell, Python, JavaScript and Bats suites. Bats covers
branch/worktree operations, update detection and VUR overlays. Missing Bats is
an error.

`tests/test_paths.py` checks repository-owned file references, Python `Path`
joins, directory boundaries and local website links. Optional inputs and test
fixtures have scoped exceptions. Dynamic paths, XBPS builds and remote
publication also need integration testing.

Tooling CI uses actionlint 1.7.12. `.github/actionlint.yaml` exempts only its
unsupported `concurrency.queue` diagnostic in the three queued workflows.
