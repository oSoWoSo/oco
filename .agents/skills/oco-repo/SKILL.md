---
name: oco-repo
description: "Use when maintaining, developing, debugging, or fixing template build problems in the oco (vOid Community repOsitory) Void Linux package repository. Covers ocoman regeneration, xbps-src builds, xlint, shlibs, autobump groups, CI workflows, and common template pitfalls."
---

# oco repository maintenance

oco is the **vOid Community repOsitory**: a collection of `xbps-src` template files for Void Linux, hosted on Codeberg/GitHub. Templates live under `srcpkgs/<pkg>/template`. The repo also ships CI, website generation, and an autobump system.

## When to use this skill

- Editing or adding a template under `srcpkgs/`.
- Fixing a failing template build (local `xbps-src` or CI `build.yml`).
- Regenerating `README.md` and the template list after template changes.
- Managing package groups / autobump packs.
- Debugging CI workflows (build, autobump, scan, feed, sync).
- Working with shlibs (`shlibs_append`, `shlibs_remove`).

## Repository layout

```
oco/
├── srcpkgs/<pkg>/template      # one template per package
├── .github/workflows/          # hand-maintained CI workflows (no .yml.in generator)
├── config/autobump-packs.tsv  # package groups for autobump
├── config/autobump-dependencies.tsv
├── .github/scripts/            # CI helpers (build-detect, autobump-*, osv-advisory, …)
├── bump.sh                     # local package-group helper
├── ocoman                      # repo manager (regenerate, init, upload, …)
├── shlibs_append               # shlibs to add to void-packages/common/shlibs
├── shlibs_remove               # shlibs to remove
├── tests/                      # bats + python tests for helpers
├── website/public/             # allowlisted public assets only
├── website/templates/          # private site-generation inputs
├── config/                     # package groups, blacklists, feeds, OSV mapping
├── lib/                        # shared shell helpers
└── tools/                      # build, autobump, repository, updates, website, community tools
```

## Golden rules (from project memory)

1. **Edit `.github/workflows/*.yml` directly.** Workflow templates (`src/*.yml.in`) and their generator have been removed; `./ocoman -u` only updates repository metadata.
2. **One commit per template**, message `<pkgname> <version>`.
3. After adding a template, run `./ocoman -u` to regenerate the template list/table.
4. When changing an upstream shlib from void-packages, reflect it in `shlibs_remove` and `shlibs_append`.
5. New shlib → add only to `shlibs_append`.
6. `CLAUDE.md` is not tracked; remote default branch is `OCO`.
7. Remote writes (`gh workflow run`, pushes) are user-only actions — never perform without explicit request.

## Core commands

### Regenerate repo metadata
```sh
./ocoman -u          # update list and README
./ocoman -uw         # update + rebuild website
./ocoman -h          # full help
```

### Lint a template
```sh
xlint <pkgname>      # run from void-packages checkout with OCO srcpkgs copied in
```
`xlint` is `/usr/bin/xlint` on this machine.

### Build a package locally
```sh
# from void-packages checkout ($XBPS_DISTDIR, default ~/void)
./xbps-src -Q pkg <pkgname>
```
Tests must be allowed in `$XBPS_DISTDIR/etc/conf`. Build matrix: x86_64, aarch64, plus musl variants. A common smoke target is x86_64 and aarch64-musl crossbuild.

### Apply shlibs patches to a checkout
```sh
./ocoman -l          # uses CLONE_DEST (default $XBPS_DISTDIR or ~/void)
# or: SHLIBS_FILE=... CLONE_DEST=... ./ocoman -l
```

### Clone / bootstrap
```sh
./ocoman -i          # clone void-packages + OCO into CLONE_DEST, apply shlibs
./ocoman -o          # add OCO remote/branch to existing void-packages checkout
```
Destination override: `CLONE_DEST`, `CLONE_TEMP`, `CLONE_DEPTH`, `OCO_BRANCH`, `SHLIBS_FILE`.

### Package groups / autobump
```sh
./bump.sh <group> <operation>
```
Operations: `--lint`, `--build`, `--bump`, `--copy`, `--install`, `--order`, `--all`.
Env: `XBPS_DISTDIR` or `CLONE_DEST` (default `~/void`); `sourceDir`, `destinationDir` override srcpkgs dirs.
`--order`/`--build` use `xbps-src sort-dependencies` (no compile). Add a group + glob patterns to `config/autobump-packs.tsv` to make it available to CI.

### Trigger CI build for a package
```sh
./ocoman -t <pkg...>   # gum menu if no pkg; dispatches GitHub CI build
```

### Upload built packages (Surfer CLI)
```sh
./ocoman -p
```

## Template anatomy & common pitfalls

A template is a shell script defining variables (`pkgname`, `version`, `revision`, `short_desc`, `maintainer`, `license`, `homepage`, `distfiles`, `checksum`, `build_style`, …) and optional functions (`do_build`, `do_install`, `post_install`, …).

Pitfalls to check when a build fails:

- **Checksum mismatch**: recompute with `xbps-src`/`xgensum`; update `checksum` (and `distfiles`).
- **Missing build deps**: add to `hostmakedepends` / `makedepends` / `depends`.
- **shlib changes**: if upstream void-packages changed a shlib, update `shlibs_remove`/`shlibs_append`; new shlib → `shlibs_append` only.
- **`nocross` builds**: some templates set `nocross=yes`; cross-build matrix may fail. Note project memory: nocross builds are currently broken in some contexts.
- **Architecture gating**: templates may use `case "$XBPS_TARGET_MACHINE" in …` for arch-specific sources.
- **Revision bumps**: autobump only revision-bumps known direct consumers of changed packages; missing deps surface at build time.
- **Tests**: CI builds with tests enabled; a template's `do_check()` must pass. Disable only with justification.
- **Licensing / fetch**: `distfiles` must be reachable; CI runs in `oco-builder` image.

### Debugging a failing build

1. Reproduce locally first:
   ```sh
   cd ~/void && ./xbps-src -Q pkg <pkg>
   ```
   Read the full log; note the failing phase (fetch / configure / build / check / install).
2. Lint: `xlint <pkg>`.
3. Check dependencies resolve: `./xbps-src show-build-deps <pkg>` (used by CI autobump).
4. For arch-specific failures, crossbuild: build for the failing arch explicitly.
5. Inspect `hostdir/` / `masterdir-*/` for leftover state; clean with `./xbps-src clean <pkg>` or remove build dir.
6. Check CI: `.github/workflows/build.yml` detects changed templates under `srcpkgs/` and builds affected packages with required build deps in `oco-builder`.

### Debugging CI

- Read `.github/CI.md` for the workflow inventory, trust boundaries, and publication flow.
- Workflows: `build.yml`, `bump.yml` (📦 bumper; the only autobump entry point), `autobump-release.yml`, `scan.yml`, `update.yml`, `feed-update.yml`, `vur-check.yml`, `write-surfer.yml`, `mirror.yml`, `sync-codeberg-to-github.yml`.
- Validate syntax with `actionlint -shellcheck= -pyflakes=`. `.github/actionlint.yaml` narrowly exempts the unsupported `concurrency.queue` diagnostic; keep queuing on the three serialized merge/write jobs.
- `tooling.yml` runs `node --check website/public/main.js` and helper tests (bats + python) under `tests/`.
- CI uses `oco-builder` image; confirm image tag references (memory: check whether CI always resolves newest image).

## Autobump system

- There is no autobump whitelist; all non-blacklisted real templates are eligible.
- Blacklist: `config/autobump-blacklist`.
- Packs: `config/autobump-packs.tsv` (group + glob patterns).
- Dependencies: `config/autobump-dependencies.tsv`.
- Autobump dispatch: `ocoman autobump <pkg> [--force]` (force ignores blacklist), dispatches the 📦 bumper workflow.
- CI: the 📦 bumper workflow (`bump.yml`) runs in `oco-builder`, resolves graph via `xbps-src show-build-deps` without compiling; checks whole pack for newer versions; revision-bumps known direct consumers. It answers `package-update` issues and dispatches single templates.
- Ruleset 23215878 blocks deletion of `autobump/*` branches.

## Shlibs

- `shlibs_append`: shlibs to add to void-packages `common/shlibs`.
- `shlibs_remove`: shlibs to remove (when upstream changed).
- Apply with `./ocoman -l`.

## Tests

```sh
python3 -m venv /tmp/oco-tests
/tmp/oco-tests/bin/pip install -r tests/requirements.txt
# zstd and bats CLIs must also be installed.
PATH="/tmp/oco-tests/bin:$PATH" sh tests/run.sh   # or individual bats/python
```
Tests cover helpers: `test_autobump_batch.py`, `test_detect_update.bats`, `test_vur_check.bats`, `test_mirror_pr.py`, `test_surfer_publish.py`, `test_osv_advisory.py`, etc. Run `tooling` workflow locally to validate.

## Verification checklist before committing

- [ ] Template lints cleanly (`xlint`).
- [ ] Builds for at least x86_64 (ideally aarch64-musl too).
- [ ] `./ocoman -u` run if template added/removed (README regenerated).
- [ ] shlibs updated if applicable.
- [ ] Commit message `<pkgname> <version>`, one template per commit.
- [ ] Workflow changes validated with actionlint and helper tests.

## Quick diagnostics

- "template not found in CI": ensure it's under `srcpkgs/` and package detection includes it.
- "stale repodata / orphan files": Surfer upload handles orphan cleanup; see project memory on CLI transport.
- "permission denied on autobump branch": ruleset 23215878 — do not delete `autobump/*`.
