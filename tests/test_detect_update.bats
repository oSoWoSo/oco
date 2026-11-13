#!/usr/bin/env bats

setup() {
  TEST_DIR="$(mktemp -d)"
  REPO="$TEST_DIR/repo"
  BIN="$TEST_DIR/bin"
  mkdir -p "$REPO/srcpkgs/fixture" "$BIN"
  printf 'pkgname=fixture\nversion=1.2.3\n' >"$REPO/srcpkgs/fixture/template"
  : >"$TEST_DIR/update-output"

  cat >"$TEST_DIR/xbps-src" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$ENGINE_ARGS"
cat "$UPDATE_OUTPUT"
EOF
  chmod +x "$TEST_DIR/xbps-src"

  cat >"$BIN/id" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$FAKE_EUID"
EOF
  cat >"$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$SUDO_ARGS"
[[ $1 == -Eu && $2 == builder ]] || exit 65
shift 2
exec "$@"
EOF
  cat >"$BIN/chown" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CHOWN_ARGS"
EOF
  chmod +x "$BIN/id" "$BIN/sudo" "$BIN/chown"

  export PATH="$BIN:$PATH"
  export XBPS_SRC="$TEST_DIR/xbps-src"
  export ENGINE_ARGS="$TEST_DIR/engine-args"
  export SUDO_ARGS="$TEST_DIR/sudo-args"
  export CHOWN_ARGS="$TEST_DIR/chown-args"
  export UPDATE_OUTPUT="$TEST_DIR/update-output"
  export FAKE_EUID=0
  export GH_TOKEN=test-token
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "root runs update-check as builder with readable token credentials" {
  run bash "$BATS_TEST_DIRNAME/../.github/scripts/detect-update.sh" fixture "$REPO"
  [ "$status" -eq 0 ]
  [ "$(cat "$SUDO_ARGS")" = "$(printf '%s\n' -Eu builder "$XBPS_SRC" update-check fixture)" ]
  [ "$(cat "$ENGINE_ARGS")" = "$(printf '%s\n' update-check fixture)" ]
  [ "$(head -n 2 "$CHOWN_ARGS")" = "$(printf '%s\n' -R builder:builder)" ]
}

@test "non-root update-check runs directly without sudo" {
  export FAKE_EUID=1000
  unset GH_TOKEN
  run bash "$BATS_TEST_DIRNAME/../.github/scripts/detect-update.sh" fixture "$REPO"
  [ "$status" -eq 0 ]
  [ ! -e "$SUDO_ARGS" ]
  [ "$(cat "$ENGINE_ARGS")" = "$(printf '%s\n' update-check fixture)" ]
}
