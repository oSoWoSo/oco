#!/usr/bin/env bats
# update-metadata.sh writes the source_sha for the Surfer publication request.
# The publish job later checks that SHA out from the remote, so it must always
# be a commit that exists on the pushed branch. A local commit --amend would
# point source_sha at an unpushed commit and break "Checkout publication
# source" in write-surfer.yml (regression from ba10d41). These tests run the
# real script against a scratch repo.

setup() {
  TEST_DIR="$(mktemp -d)"
  REPO="$TEST_DIR/repo"
  mkdir -p "$REPO/srcpkgs/fixture"
  printf 'pkgname=fixture\nversion=1.2.3\n' >"$REPO/srcpkgs/fixture/template"
  git init -q -b OCO "$REPO"
  git -C "$REPO" config user.name "oSoWoSo-bot"
  git -C "$REPO" config user.email "mail@osowoso.org"
  printf '#!/srcpkgs/fixture\n' >"$REPO/.gitignore"
  printf '# OCO\n' >"$REPO/README.md"
  git -C "$REPO" add . && git -C "$REPO" commit -qm "fixture: init"
  export GITHUB_OUTPUT="$TEST_DIR/output"
  export RUNNER_TEMP="$TEST_DIR/runner-temp"
  : >"$GITHUB_OUTPUT"
}

teardown() {
  rm -rf "$TEST_DIR"
}

run_update_metadata() {
  (cd "$REPO" && bash "$BATS_TEST_DIRNAME/../.github/scripts/ci/update-metadata.sh")
}

head_sha() {
  git -C "$REPO" rev-parse HEAD
}

@test "source_sha matches HEAD when metadata is untouched" {
  run_update_metadata

  [ "$(grep '^source_sha=' "$GITHUB_OUTPUT")" = "source_sha=$(head_sha)" ]
}

@test "regenerated metadata is not committed and source_sha stays at pushed HEAD" {
  before="$(head_sha)"
  # Simulate `./ocoman -u` producing a metadata change in the worktree.
  printf '#!/srcpkgs/fixture\n!/srcpkgs/newpkg\n' >"$REPO/.gitignore"
  printf '# OCO\n| newpkg | 1.0 | x |\n' >"$REPO/README.md"

  run_update_metadata

  [ "$(head_sha)" = "$before" ]
  [ "$(grep '^source_sha=' "$GITHUB_OUTPUT")" = "source_sha=$before" ]
  # The generated changes are left for the author to commit, never amended.
  git -C "$REPO" status --porcelain | grep -q '^ M .gitignore'
  git -C "$REPO" status --porcelain | grep -q '^ M README.md'
  [ -z "$(git -C "$REPO" log --oneline -1 | grep -E 'CI: update|README')" ]
}

@test "publication manifest records the pushed source_sha" {
  run_update_metadata

  manifest="$RUNNER_TEMP/surfer-publication/manifest.json"
  [ -f "$manifest" ]
  expect="$(head_sha)" python3 -c "
import json, os, sys
d = json.load(open(sys.argv[1]))
assert d['source_sha'] == os.environ['expect'], (d['source_sha'], os.environ['expect'])
assert d['update_main_index'] is True
assert d['destination'] == 'production'
" "$manifest"
}