#!/usr/bin/env bash
set -euo pipefail

{
  echo "# Update scan"
  echo
  if [ -s out/found ]; then
    echo "| Package | Current | Latest |"
    echo "|---|---|---|"
    while read -r pkg old new; do
      echo "| \`$pkg\` | $old | **$new** |"
    done <out/found
  else
    echo "All non-blacklisted templates are up to date."
  fi
} >>"$GITHUB_STEP_SUMMARY"
