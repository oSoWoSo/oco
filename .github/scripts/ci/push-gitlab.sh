#!/usr/bin/env bash
set -euo pipefail

: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"
: "${GITLAB_REPO:?GITLAB_REPO is required (e.g. https://gitlab.com/osowoso/oco.git)}"
: "${BRANCH:?BRANCH is required}"
: "${FORCE:?FORCE must be 0 or 1}"

auth=$(printf 'oauth2:%s' "$GITLAB_TOKEN" | base64 -w0)

case "$FORCE" in
  0) git -c "http.extraheader=Authorization: Basic ${auth}" push "$GITLAB_REPO" "HEAD:refs/heads/$BRANCH" ;;
  1) git -c "http.extraheader=Authorization: Basic ${auth}" push "$GITLAB_REPO" "HEAD:refs/heads/$BRANCH" --force ;;
  *) printf 'FORCE must be 0 or 1\n' >&2; exit 2 ;;
esac
