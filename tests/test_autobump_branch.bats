#!/usr/bin/env bats

setup() {
  TEST_DIR="$(mktemp -d)"
  export TEST_DIR
  export ORIGIN="$TEST_DIR/origin.git"
  export WORK="$TEST_DIR/work"
  export RUNNER_TEMP="$TEST_DIR/runner"
  mkdir -p "$WORK" "$RUNNER_TEMP"
  git init --bare -q "$ORIGIN"
  git -C "$WORK" init -qb OCO
  git -C "$WORK" config user.name test
  git -C "$WORK" config user.email test@example.invalid
  mkdir -p "$WORK/srcpkgs/alpha" "$WORK/.github"
  cat >"$WORK/srcpkgs/alpha/template" <<'EOF'
pkgname=alpha
version=1.0
revision=1
EOF
  printf 'test\talpha\n' >"$WORK/.github/autobump-packs.tsv"
  printf 'base README\n' >"$WORK/README.md"
  git -C "$WORK" add .
  git -C "$WORK" commit -qm base
  git -C "$WORK" remote add origin "$ORIGIN"
  git -C "$WORK" push -q origin OCO
  mkdir -p "$TEST_DIR/bin"
  export REAL_GIT="$(command -v git)"
  cat >"$TEST_DIR/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == push ]]; then
  printf '%s\n' "$*" >>"$PUSH_LOG"
  exit 0
fi
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$TEST_DIR/bin/git"
  cat >"$WORK/ocoman" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == -u ]] || exit 2
printf 'regenerated README\n' >README.md
EOF
  chmod +x "$WORK/ocoman"
  export PATH="$TEST_DIR/bin:$PATH"
  export PUSH_LOG="$TEST_DIR/push.log"
  export TEMPLATE=alpha VERSION=1.1 OCO_TOKEN=fake GH_REPO=test/repo
  export GITHUB_ENV="$TEST_DIR/github-env" GITHUB_OUTPUT="$TEST_DIR/github-output"
  export BRANCH_SCRIPT="$BATS_TEST_DIRNAME/../.github/scripts/ci/autobump-branch.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

prepare_bump() {
  cat >"$WORK/srcpkgs/alpha/template" <<'EOF'
pkgname=alpha
version=1.1
revision=1
EOF
  printf 'alpha\t1.1\tversion\t0\n' >"$RUNNER_TEMP/autobump-plan.tsv"
}

@test "pack cache survives OCO reset and is amended with refreshed template hash" {
  prepare_bump
  digest="$(sha256sum "$WORK/srcpkgs/alpha/template")"
  digest="${digest%% *}"
  printf '# autobump-dependencies-v1\nalpha\t%s\t\n' "$digest" >"$WORK/.github/autobump-dependencies.tsv"

  cd "$WORK"
  run env RUNNER_TEMP="$RUNNER_TEMP" TEMPLATE="$TEMPLATE" VERSION="$VERSION" \
    OCO_TOKEN="$OCO_TOKEN" GH_REPO="$GH_REPO" GITHUB_ENV="$GITHUB_ENV" \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" PATH="$PATH" PUSH_LOG="$PUSH_LOG" \
    REAL_GIT="$REAL_GIT" bash "$BRANCH_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(git rev-list --count origin/OCO..HEAD)" -eq 1 ]
  [ -n "$(git show HEAD:.github/autobump-dependencies.tsv)" ]
  committed_hash="$(git show HEAD:.github/autobump-dependencies.tsv | awk -F '\t' '$1 == "alpha" { print $2 }')"
  actual_hash="$(sha256sum srcpkgs/alpha/template)"
  actual_hash="${actual_hash%% *}"
  [ "$committed_hash" = "$actual_hash" ]
  [ "$(git show HEAD:.github/autobump-dependencies.tsv | awk -F '\t' '$1 == "alpha" { print $3 }')" = "" ]
  [ -s "$PUSH_LOG" ]
}

@test "singleton plan does not create a dependency manifest" {
  prepare_bump
  cd "$WORK"
  run env RUNNER_TEMP="$RUNNER_TEMP" TEMPLATE="$TEMPLATE" VERSION="$VERSION" \
    OCO_TOKEN="$OCO_TOKEN" GH_REPO="$GH_REPO" GITHUB_ENV="$GITHUB_ENV" \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" PATH="$PATH" PUSH_LOG="$PUSH_LOG" \
    REAL_GIT="$REAL_GIT" bash "$BRANCH_SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -e .github/autobump-dependencies.tsv ]
  ! git show HEAD:.github/autobump-dependencies.tsv >/dev/null 2>&1
  [ "$(git rev-list --count origin/OCO..HEAD)" -eq 1 ]
}
