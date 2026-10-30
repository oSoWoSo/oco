#!/usr/bin/env bash
set -euo pipefail

# Every package that moved to a new upstream version is checked;
# the revision-only bumps carry no new upstream code.
# Keep the accumulated section comfortably below GitHub's 65536-char PR body
# limit; each per-package report is capped by osv-advisory.py --max-chars.
: >"$RUNNER_TEMP/osv-report.md"
while IFS=$'\t' read -r package version kind _order; do
  [[ -n $package ]] || continue
  [[ $kind == version ]] || continue
  report="$RUNNER_TEMP/osv-$package.md"
  if ! python3 .github/scripts/osv-advisory.py "$package" "$version" --all-upstream \
    --mapping .github/osv-identities.json \
    --max-chars 15000 \
    --output "$report"; then
    printf '### OSV advisory check: error\n\n**ERROR:** Advisory report for `%s` could not be generated; no clean result is implied.\n' \
      "$package" >>"$RUNNER_TEMP/osv-report.md"
    continue
  fi
  # Hard stop so a many-package batch can never overflow the body.
  allowed=$((65536 - $(wc -c <"$RUNNER_TEMP/osv-report.md")))
  if [[ $allowed -le 0 ]]; then
    printf '\n_(Further OSV reports omitted to keep the PR body under the size limit.)_\n' \
      >>"$RUNNER_TEMP/osv-report.md"
    break
  fi
  if [[ $(wc -c <"$report") -gt $allowed ]]; then
    head -c "$allowed" "$report" >>"$RUNNER_TEMP/osv-report.md"
    printf '\n_(OSV report section truncated to keep the PR body under the size limit.)_\n' \
      >>"$RUNNER_TEMP/osv-report.md"
    break
  fi
  cat "$report" >>"$RUNNER_TEMP/osv-report.md"
  printf '\n' >>"$RUNNER_TEMP/osv-report.md"
done <"$RUNNER_TEMP/autobump-plan.tsv"
