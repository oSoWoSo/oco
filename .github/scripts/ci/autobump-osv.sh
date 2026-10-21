#!/usr/bin/env bash
set -euo pipefail

# Every package that moved to a new upstream version is checked;
# the revision-only bumps carry no new upstream code.
: >"$RUNNER_TEMP/osv-report.md"
while IFS=$'\t' read -r package version kind _order; do
  [[ -n $package ]] || continue
  [[ $kind == version ]] || continue
  report="$RUNNER_TEMP/osv-$package.md"
  if ! python3 .github/scripts/osv-advisory.py "$package" "$version" --all-upstream \
    --mapping .github/osv-identities.json \
    --output "$report"; then
    printf '### OSV advisory check: error\n\n**ERROR:** Advisory report for `%s` could not be generated; no clean result is implied.\n' \
      "$package" >>"$RUNNER_TEMP/osv-report.md"
    continue
  fi
  cat "$report" >>"$RUNNER_TEMP/osv-report.md"
  printf '\n' >>"$RUNNER_TEMP/osv-report.md"
done <"$RUNNER_TEMP/autobump-plan.tsv"
