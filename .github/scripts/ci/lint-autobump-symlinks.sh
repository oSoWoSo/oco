#!/usr/bin/env bash
set -euo pipefail

output=$(mktemp)
trap 'rm -f "$output"' EXIT

if .github/scripts/lint-autobump-symlinks.sh >"$output" 2>&1; then
  status=0
else
  status=$?
fi

cat "$output"
if [ "$status" -ne 0 ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ] &&
    ! grep -Fq '<!-- lint-autobump-symlinks -->' "$GITHUB_STEP_SUMMARY"; then
  {
    printf '<!-- lint-autobump-symlinks -->\n### error:  \n'
    grep -i 'error:' "$output" | cut -d' ' -f2 | cut -d'/' -f2 || true
  } >> "$GITHUB_STEP_SUMMARY"
fi

exit "$status"
