#!/usr/bin/env bash
set -euo pipefail

git config user.name "oSoWoSo-bot"
git config user.email "mail@osowoso.org"
git add .gitignore
if ! git diff --cached --quiet; then
  # Amend generated metadata into the current HEAD
  git commit --amend --no-edit
fi

source_sha=$(git rev-parse HEAD)
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  echo "source_sha=$source_sha" >> "$GITHUB_OUTPUT"
else
  echo "source_sha=$source_sha"
fi

publication_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/surfer-publication"
run_id="${RUN_ID:-0}"
python3 tools/repository/surfer-publish.py "$publication_dir" --create --destination production \
  --source-sha "$source_sha" --source-run-id "$run_id" --update-main-index
