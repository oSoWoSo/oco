#!/bin/sh
# Tests for .github/scripts/ci/push-mirror.sh: one helper pushes the checked-out
# HEAD to the host named by $HOST, with an optional --force. Aligned with the
# other helper tests run from tests/run.sh.

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
PUSH_SH="$SCRIPT_DIR/.github/scripts/ci/push-mirror.sh"

# Isolated HOME: the script writes ~/.ssh there for the SSH hosts.
HOME_DIR=$(mktemp -d)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$HOME_DIR" "$TMP_DIR"' EXIT INT TERM

git_do() {
        git -c user.email=test@example.com -c user.name=test "$@"
}

# Each host is a local bare repository, so the real push path runs end to end
# without a network or an SSH server.
for _h in codeberg gitlab tangled; do
        git_do init -q --bare "$TMP_DIR/$_h.git"
done

git_do init -q -b OCO "$TMP_DIR/work"
cd "$TMP_DIR/work" || exit 1
git_do commit -q --allow-empty -m first
git_do push -q "$TMP_DIR/codeberg.git" OCO
git_do push -q "$TMP_DIR/gitlab.git" OCO
git_do push -q "$TMP_DIR/tangled.git" OCO
git_do commit -q --allow-empty -m second

push_mirror() {
        HOME="$HOME_DIR" \
        CODEBERG_REPO="$TMP_DIR/codeberg.git" \
        CODEBERG_SSH_KEY=dummy-key \
        CODEBERG_KNOWN_HOSTS=dummy-host \
        GITLAB_REPO="$TMP_DIR/gitlab.git" \
        GITLAB_TOKEN=dummy-token \
        TANGLED_REPO="$TMP_DIR/tangled.git" \
        TANGLED_SSH_KEY=dummy-key \
        TANGLED_KNOWN_HOSTS=dummy-host \
        BRANCH="${BRANCH:-OCO}" \
        bash "$PUSH_SH"
}

head_of() {
        git --git-dir "$TMP_DIR/$1.git" rev-parse "$2" 2>/dev/null
}

expect_rc() {
        _got=$1 _want=$2 _what=$3
        [ "$_got" -eq "$_want" ] && return 0
        echo "FAIL: $_what (rc=$_got, want=$_want)"
        exit 1
}

expect_eq() {
        [ "$1" = "$2" ] && return 0
        echo "FAIL: $3"
        echo "      got:  $1"
        echo "      want: $2"
        exit 1
}

# --- a fast-forward push per host ---------------------------------------
for _h in codeberg gitlab tangled; do
        HOST=$_h push_mirror >/dev/null 2>&1
        expect_rc $? 0 "$_h: fast-forward push failed"
        expect_eq "$(head_of "$_h" OCO)" "$(git rev-parse HEAD)" \
                "$_h: remote OCO did not move to HEAD"
done

# --- the SSH hosts install the key and its known_hosts -------------------
expect_eq "$(cat "$HOME_DIR/.ssh/id_ed25519")" 'dummy-key' 'codeberg: key not written'
expect_eq "$(cat "$HOME_DIR/.ssh/known_hosts")" 'dummy-host' 'codeberg: known_hosts not written'
expect_eq "$(stat -c '%a' "$HOME_DIR/.ssh/id_ed25519")" '600' 'key must not be world-readable'

# --- a divergent history is refused without FORCE -----------------------
git_do reset -q --hard HEAD~1
git_do commit -q --allow-empty -m divergent
_before=$(head_of codeberg OCO)
HOST=codeberg push_mirror >/dev/null 2>&1
expect_rc $? 1 'codeberg: divergent push must fail without FORCE'
expect_eq "$(head_of codeberg OCO)" "$_before" 'codeberg: refused push still moved the remote'

# --- ...and replaced with FORCE=1 ---------------------------------------
HOST=codeberg FORCE=1 push_mirror >/dev/null 2>&1
expect_rc $? 0 'codeberg: FORCE=1 push failed'
expect_eq "$(head_of codeberg OCO)" "$(git rev-parse HEAD)" \
        'codeberg: FORCE=1 did not replace the remote branch'

# --- the branch name is honoured ---------------------------------------
git_do branch -q -f feature
BRANCH=feature HOST=gitlab push_mirror >/dev/null 2>&1
expect_rc $? 0 'gitlab: push of a non-default branch failed'
expect_eq "$(head_of gitlab feature)" "$(git rev-parse HEAD)" \
        'gitlab: BRANCH was not honoured'

# --- argument validation -------------------------------------------------
HOST=sourcehut push_mirror >/dev/null 2>&1
expect_rc $? 2 'an unknown host must exit 2'

HOST=codeberg FORCE=2 push_mirror >/dev/null 2>&1
expect_rc $? 2 'FORCE=2 must exit 2'

out=$(HOST=codeberg FORCE=1 BRANCH='' bash "$PUSH_SH" 2>&1)
expect_rc $? 1 'a missing BRANCH must exit 1'
case "$out" in
*BRANCH*) ;;
*) echo "FAIL: a missing BRANCH should be named: $out"; exit 1 ;;
esac

# Only the selected host's credentials are required: a tangled run must not
# demand the Codeberg or GitLab variables. A fresh branch keeps the push a
# creation, so this asserts on the credentials, not on the divergence above.
out=$(HOME="$HOME_DIR" TANGLED_REPO="$TMP_DIR/tangled.git" TANGLED_SSH_KEY=k \
        TANGLED_KNOWN_HOSTS=h BRANCH=credentials-only HOST=tangled bash "$PUSH_SH" 2>&1)
expect_rc $? 0 "tangled must not need the other hosts' credentials"

out=$(HOME="$HOME_DIR" GITLAB_REPO="$TMP_DIR/gitlab.git" BRANCH=OCO HOST=gitlab \
        bash "$PUSH_SH" 2>&1)
expect_rc $? 1 'a missing GITLAB_TOKEN must exit 1'
case "$out" in
*GITLAB_TOKEN*) ;;
*) echo "FAIL: a missing GITLAB_TOKEN should be named: $out"; exit 1 ;;
esac

echo 'push-mirror.sh: all checks passed'
