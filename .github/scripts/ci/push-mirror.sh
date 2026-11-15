#!/usr/bin/env bash
# Push the checked-out HEAD to one mirror host.
#
# Callers set HOST (codeberg, gitlab or tangled), BRANCH and, optionally,
# FORCE=1. Every host's credentials and repository arrive as environment
# variables; only the ones the selected host needs are required, so the
# workflow can hand all of them to a single script.
set -euo pipefail

: "${HOST:?HOST is required (codeberg, gitlab or tangled)}"
: "${BRANCH:?BRANCH is required}"

case "${FORCE:-0}" in
  0) ;;
  1) ;;
  *) printf 'FORCE must be 0 or 1\n' >&2; exit 2 ;;
esac

_git=(git)

case "$HOST" in
  codeberg|tangled)
    if [ "$HOST" = codeberg ]; then
      : "${CODEBERG_SSH_KEY:?CODEBERG_SSH_KEY is required}"
      : "${CODEBERG_KNOWN_HOSTS:?CODEBERG_KNOWN_HOSTS is required}"
      url="${CODEBERG_REPO:?CODEBERG_REPO is required}"
      key="$CODEBERG_SSH_KEY" known_hosts="$CODEBERG_KNOWN_HOSTS"
    else
      : "${TANGLED_SSH_KEY:?TANGLED_SSH_KEY is required}"
      : "${TANGLED_KNOWN_HOSTS:?TANGLED_KNOWN_HOSTS is required}"
      url="${TANGLED_REPO:?TANGLED_REPO is required}"
      key="$TANGLED_SSH_KEY" known_hosts="$TANGLED_KNOWN_HOSTS"
    fi
    mkdir -p "$HOME/.ssh"
    printf '%s\n' "$key" > "$HOME/.ssh/id_ed25519"
    chmod 600 "$HOME/.ssh/id_ed25519"
    printf '%s\n' "$known_hosts" > "$HOME/.ssh/known_hosts"
    # Both knots and Forgejo reject the push when the client offers keys the
    # account does not have, so offer only the key written above.
    export GIT_SSH_COMMAND="ssh -i ${HOME}/.ssh/id_ed25519 -o IdentitiesOnly=yes"
    ;;
  gitlab)
    : "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"
    url="${GITLAB_REPO:?GITLAB_REPO is required}"
    auth=$(printf 'oauth2:%s' "$GITLAB_TOKEN" | base64 -w0)
    _git=(git -c "http.extraheader=Authorization: Basic ${auth}")
    ;;
  *)
    printf 'HOST must be codeberg, gitlab or tangled (got: %s)\n' "$HOST" >&2
    exit 2
    ;;
esac

git remote remove mirror >/dev/null 2>&1 || true
git remote add mirror "$url"

if [ "${FORCE:-0}" = 1 ]; then
  "${_git[@]}" push mirror "HEAD:refs/heads/${BRANCH}" --force
else
  "${_git[@]}" push mirror "HEAD:refs/heads/${BRANCH}"
fi
