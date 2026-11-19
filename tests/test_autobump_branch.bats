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
