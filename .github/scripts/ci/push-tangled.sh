#!/usr/bin/env bash
set -euo pipefail

: "${SSH_PRIVATE_KEY:?SSH_PRIVATE_KEY is required}"
: "${SSH_KNOWN_HOSTS:?SSH_KNOWN_HOSTS is required}"
: "${TANGLED_REPO:?TANGLED_REPO is required}"
: "${BRANCH:?BRANCH is required}"
: "${FORCE:?FORCE must be 0 or 1}"

mkdir -p "$HOME/.ssh"
printf '%s\n' "$SSH_PRIVATE_KEY" > "$HOME/.ssh/id_ed25519"
chmod 600 "$HOME/.ssh/id_ed25519"
printf '%s\n' "$SSH_KNOWN_HOSTS" > "$HOME/.ssh/known_hosts"

# Tangled knots reject the push when the client offers keys the account does
# not have, so offer only the key written above.
export GIT_SSH_COMMAND="ssh -i ${HOME}/.ssh/id_ed25519 -o IdentitiesOnly=yes"

if ! git remote get-url tangled >/dev/null 2>&1; then
  git remote add tangled "$TANGLED_REPO"
fi

case "$FORCE" in
  0) git push tangled "HEAD:refs/heads/$BRANCH" ;;
  1) git push tangled "HEAD:refs/heads/$BRANCH" --force ;;
  *) printf 'FORCE must be 0 or 1\n' >&2; exit 2 ;;
esac
