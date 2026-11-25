#!/usr/bin/env bats

setup() {
  TEST_DIR="$(mktemp -d)"
  export TEST_DIR ORIGIN="$TEST_DIR/origin.git" WORK="$TEST_DIR/work"
  export RUNNER_TEMP="$TEST_DIR/runner"
  mkdir -p "$WORK" "$RUNNER_TEMP" "$TEST_DIR/bin"
  git init --bare -q "$ORIGIN"
  git -C "$WORK" init -qb OCO
  git -C "$WORK" config user.name test
  git -C "$WORK" config user.email test@example.invalid
  mkdir -p "$WORK/srcpkgs/alpha" "$WORK/config"
  printf 'pkgname=alpha\nversion=1.0\nrevision=1\n' >"$WORK/srcpkgs/alpha/template"
  printf 'test\talpha\n' >"$WORK/config/autobump-packs.tsv"
  printf 'base README\n' >"$WORK/README.md"
  git -C "$WORK" add .
  git -C "$WORK" commit -qm base
  git -C "$WORK" remote add origin "$ORIGIN"
  git -C "$WORK" push -q origin OCO
  export REAL_GIT="$(command -v git)"
  # All pushes are restricted to the local fixture, including the script's
  # GitHub URL. Exercise actual Git commits/refs without any remote writes.
  cat >"$TEST_DIR/bin/git" <<'EOF'
#!/usr/bin/env bash
args=()
if [[ ${1:-} == -C ]]; then
  args=(-C "$2")
  shift 2
fi
if [[ ${1:-} == push ]]; then
  [[ ${MOCK_PUSH_FAIL:-false} != true ]] || exit 41
  printf 'local push\n' >>"$PUSH_LOG"
  exec "$REAL_GIT" "${args[@]}" push --force "$ORIGIN" "${@: -1}"
fi
exec "$REAL_GIT" "${args[@]}" "$@"
EOF
  chmod +x "$TEST_DIR/bin/git"
  export PATH="$TEST_DIR/bin:$PATH" PUSH_LOG="$TEST_DIR/push.log"
  export TEMPLATE=alpha VERSION=1.1 OCO_TOKEN=fake GH_REPO=test/repo
  export GITHUB_ENV="$TEST_DIR/github-env" GITHUB_OUTPUT="$TEST_DIR/github-output"
  export BRANCH_SCRIPT="$BATS_TEST_DIRNAME/../.github/scripts/autobump-branch.sh"
  cd "$WORK"
}

teardown() {
  rm -rf "$TEST_DIR"
}

prepare_bump() {
  printf 'pkgname=alpha\nversion=1.1\nrevision=1\n' >srcpkgs/alpha/template
  printf 'alpha\t1.1\tversion\t0\n' >"$RUNNER_TEMP/autobump-plan.tsv"
}

prepare_cache() {
  printf '# autobump-dependencies-v1\nalpha\tstale-hash\t\n' >config/autobump-dependencies.tsv
}

assert_pushed() {
  ref="refs/heads/${1:-autobump/alpha}"
  [ "$(git --git-dir="$ORIGIN" rev-list --count "OCO..$ref")" -eq 1 ]
  git --git-dir="$ORIGIN" show "$ref:srcpkgs/alpha/template" | grep -qx 'version=1.1'
  [ -s "$PUSH_LOG" ]
  [ "$(git worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]
}

@test "pack cache is committed with the refreshed template hash without changing the caller" {
  prepare_bump
  prepare_cache
  before=$(git status --porcelain)
  run bash "$BRANCH_SCRIPT"
  [ "$status" -eq 0 ]
  assert_pushed
  [ "$(git branch --show-current)" = OCO ]
  [ "$(git status --porcelain)" = "$before" ]
  committed_hash=$(git --git-dir="$ORIGIN" show "$ref:config/autobump-dependencies.tsv" | awk -F '\t' '$1 == "alpha" { print $2 }')
  actual_hash=$(sha256sum srcpkgs/alpha/template)
  [ "$committed_hash" = "${actual_hash%% *}" ]
  grep -q stale-hash config/autobump-dependencies.tsv
}

@test "singleton plan does not create a dependency manifest" {
  prepare_bump
  run bash "$BRANCH_SCRIPT"
  [ "$status" -eq 0 ]
  assert_pushed
  ! git --git-dir="$ORIGIN" show "$ref:config/autobump-dependencies.tsv" >/dev/null 2>&1
}

@test "dispatch tooling survives branching onto an older-layout OCO base" {
  mkdir .github
  git mv config/autobump-packs.tsv .github/autobump-packs.tsv
  git commit -qm 'legacy base'
  git push -q origin OCO
  git checkout -qb WIP/CI
  git mv .github/autobump-packs.tsv config/autobump-packs.tsv
  mkdir -p .github/scripts
  printf 'workflow helper\n' >.github/scripts/next-step.sh
  git add . && git commit -qm 'new layout'
  prepare_bump
  prepare_cache
  before=$(git status --porcelain)
  run bash "$BRANCH_SCRIPT"
  [ "$status" -eq 0 ]
  assert_pushed
  [ "$(git branch --show-current)" = WIP/CI ]
  [ "$(git status --porcelain)" = "$before" ]
  [ -f .github/scripts/next-step.sh ]
  git --git-dir="$ORIGIN" show "$ref:.github/autobump-dependencies.tsv" | grep -q '^alpha'
  ! git --git-dir="$ORIGIN" cat-file -e "$ref:config" 2>/dev/null
  ! git --git-dir="$ORIGIN" cat-file -e "$ref:.github/scripts/next-step.sh" 2>/dev/null
}

@test "pack members resolve to the same branch target" {
  mkdir -p tools/autobump srcpkgs/beta
  cp "$BATS_TEST_DIRNAME/../tools/autobump/autobump_packs.py" tools/autobump/
  touch srcpkgs/beta/template config/autobump-blacklist
  printf 'test\tbeta\nsubset\tbeta\n' >>config/autobump-packs.tsv
  script="$BATS_TEST_DIRNAME/../.github/scripts/autobump-template.sh"

  for INPUT_PKG in alpha beta; do
    export INPUT_PKG
    : >"$GITHUB_OUTPUT"
    run bash "$script"
    [ "$status" -eq 0 ]
    grep -qx 'target=test' "$GITHUB_OUTPUT"
  done

  unset INPUT_PKG
  export ISSUE_BODY=$'<!-- pack-update:test -->\n<!-- pack-member:beta 2.0 -->'
  : >"$GITHUB_OUTPUT"
  run bash "$script"
  [ "$status" -eq 0 ]
  grep -qx 'target=test' "$GITHUB_OUTPUT"
  grep -qx 'template=beta' "$GITHUB_OUTPUT"

  export ISSUE_BODY=$'<!-- package-update:alpha -->\n<!-- upstream-version:1.1 -->'
  : >"$GITHUB_OUTPUT"
  run bash "$script"
  [ "$status" -eq 0 ]
  grep -qx 'target=test' "$GITHUB_OUTPUT"
}

@test "the same pack PR is reused without a push until its templates change" {
  export PACK=test
  prepare_bump
  run bash "$BRANCH_SCRIPT"
  [ "$status" -eq 0 ]
  assert_pushed autobump/test

  export MOCK_HEAD=$(git --git-dir="$ORIGIN" rev-parse refs/heads/autobump/test)
  cat >"$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'api --paginate --method GET '*base=OCO*) printf '42\t%s\toSoWoSo-bot\t%s\t%s\n' "$MOCK_HEAD" "${MOCK_REF:-autobump/test}" "${MOCK_TITLE:-test}" ;;
  *pulls/42/files*) printf 'srcpkgs/alpha/template\n' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TEST_DIR/bin/gh"
  script="$BATS_TEST_DIRNAME/../.github/scripts/autobump-existing.sh"

  # Changes outside the pack on the base don't justify rebuilding the pack.
  printf 'unrelated\n' >>README.md
  git commit -qm 'unrelated base change' README.md
  git push -q origin OCO
  : >"$PUSH_LOG"

  run bash "$script"
  [ "$status" -eq 0 ]
  grep -qx 'number=42' "$GITHUB_OUTPUT"
  grep -qx 'handled=true' "$GITHUB_OUTPUT"
  [ ! -s "$PUSH_LOG" ]

  mkdir -p tools/autobump
  cp "$BATS_TEST_DIRNAME/../tools/autobump/autobump_packs.py" tools/autobump/
  export MOCK_REF=autobump/alpha MOCK_TITLE='alpha 1.1'
  : >"$GITHUB_OUTPUT"
  run bash "$script"
  [ "$status" -eq 0 ]
  grep -qx 'branch=autobump/alpha' "$GITHUB_OUTPUT"
  grep -qx 'handled=true' "$GITHUB_OUTPUT"
  grep -qx 'retitle=true' "$GITHUB_OUTPUT"
  [ ! -s "$PUSH_LOG" ]
  unset MOCK_REF MOCK_TITLE

  printf 'pkgname=alpha\nversion=1.2\nrevision=1\n' >srcpkgs/alpha/template
  printf 'alpha\t1.2\tversion\t0\n' >"$RUNNER_TEMP/autobump-plan.tsv"
  : >"$GITHUB_OUTPUT"
  run bash "$script"
  [ "$status" -eq 0 ]
  grep -qx 'number=42' "$GITHUB_OUTPUT"
  grep -qx 'handled=false' "$GITHUB_OUTPUT"

  run bash "$BRANCH_SCRIPT"
  [ "$status" -eq 0 ]
  git --git-dir="$ORIGIN" show autobump/test:srcpkgs/alpha/template | grep -qx 'version=1.2'
  [ "$(git --git-dir="$ORIGIN" for-each-ref --format='%(refname)' refs/heads/autobump/)" = refs/heads/autobump/test ]
}

@test "pack title is used to create and refresh the same PR without closing a partial issue" {
  export PACK=test BRANCH=autobump/test ISSUE_NUMBER=10 GITHUB_REPO=test/repo
  prepare_bump
  cat >"$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'api repos/test/repo/pulls --method POST -f title=test -f head=autobump/test '*) ;;
  'api repos/test/repo/pulls/42 --method PATCH -f title=test'*) ;;
  *) exit 1 ;;
esac
printf '42\n'
EOF
  chmod +x "$TEST_DIR/bin/gh"
  script="$BATS_TEST_DIRNAME/../.github/scripts/autobump-pr.sh"
  run bash "$script"
  [ "$status" -eq 0 ]
  grep -qx 'number=42' "$GITHUB_OUTPUT"
  grep -qx 'Tracks #10' "$RUNNER_TEMP/pr-body.md"
  ! grep -q 'Closes #10' "$RUNNER_TEMP/pr-body.md"
  export EXISTING_PR=42
  run bash "$script"
  [ "$status" -eq 0 ]
  export RETITLE=true
  run bash "$script"
  [ "$status" -eq 0 ]
}

@test "testing package inputs load from the legacy tree without replacing workflow helpers" {
  touch shlibs_append shlibs_remove
  git add shlibs_append shlibs_remove
  git commit -qm shlibs
  git checkout -qb testing
  mkdir -p .github src srcpkgs/beta
  git mv config/autobump-packs.tsv .github/autobump-packs.tsv
  printf 'testing\tbeta\n' >.github/autobump-packs.tsv
  printf '# autobump-dependencies-v1\n' >.github/autobump-dependencies.tsv
  legacy_config=src
  printf 'alpha\n' >"$legacy_config/autobump-blacklist"
  printf 'pkgname=beta\nversion=1.0\nrevision=1\n' >srcpkgs/beta/template
  git add . && git commit -qm 'testing inputs'
  git push -q origin testing
  git checkout -q OCO

  mkdir -p tools/autobump
  cp "$BATS_TEST_DIRNAME/../tools/autobump/autobump_packs.py" tools/autobump/
  run bash "$BATS_TEST_DIRNAME/../.github/scripts/autobump-use-testing.sh"
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = OCO ]
  [ -f tools/autobump/autobump_packs.py ]
  git ls-files --error-unmatch srcpkgs/beta/template
  grep -qx $'testing\tbeta' config/autobump-packs.tsv
  grep -qx 'alpha' config/autobump-blacklist
}

@test "testing-targeted branches use the requested base and prefix" {
  git branch testing
  git push -q origin testing
  export BASE_REF=testing BRANCH_PREFIX=T-autobump
  prepare_bump
  run bash "$BRANCH_SCRIPT"
  [ "$status" -eq 0 ]
  assert_pushed T-autobump/alpha
  [ "$(git branch --show-current)" = OCO ]
}

@test "failed push cleans its worktree and preserves the workflow checkout" {
  prepare_bump
  before=$(git status --porcelain)
  export MOCK_PUSH_FAIL=true
  run bash "$BRANCH_SCRIPT"
  [ "$status" -eq 41 ]
  [ "$(git branch --show-current)" = OCO ]
  [ "$(git status --porcelain)" = "$before" ]
  [ "$(git worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]
}
