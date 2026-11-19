#!/usr/bin/env bash
set -euo pipefail

# Reuse an open autobump PR only when it already contains every
# package in this plan. Branches are stable (<prefix>/<template>), so
# an open PR on the exact branch this run would update is never a reason
# to skip: the newest version force-pushes over the old one in place.
# Partial single-package PRs must be folded into the complete dependency
# batch instead of suppressing it.
target_branch="${BRANCH_PREFIX:-autobump}/${TEMPLATE}"
existing_number=""
while IFS=$'\t' read -r number ref; do
  [[ -n $number ]] || continue
  [[ $ref != "$target_branch" ]] || continue
  files=$(gh api "repos/${GH_REPO}/pulls/${number}/files?per_page=100" \
    --jq '.[].filename')
  covered=true
  while IFS=$'\t' read -r package _version _kind _order; do
    [[ -n $package ]] || continue
    if ! printf '%s\n' "$files" | grep -qxF "srcpkgs/$package/template"; then
      covered=false
      break
    fi
  done <"$RUNNER_TEMP/autobump-plan.tsv"
  if [[ $covered == true ]]; then
    existing_number=$number
    break
  fi
done <<<"$(gh api "repos/${GH_REPO}/pulls?state=open&per_page=100" \
  --jq '.[] | select(.head.ref | startswith("'"${BRANCH_PREFIX:-autobump}"'/")) | "\(.number)\t\(.head.ref)"')"

if [[ -n $existing_number ]]; then
  echo "::notice::the complete batch is already covered by open pull request #${existing_number}"
  echo "number=$existing_number" >>"$GITHUB_OUTPUT"
  echo "handled=true" >>"$GITHUB_OUTPUT"
else
  echo "handled=false" >>"$GITHUB_OUTPUT"
fi
