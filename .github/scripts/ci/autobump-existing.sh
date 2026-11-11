#!/usr/bin/env bash
set -euo pipefail

# Reuse an open autobump PR only when it already contains every
# package in this plan. Partial single-package PRs must be folded
# into the complete dependency batch instead of suppressing it.
existing_number=""
while IFS=$'\t' read -r number _ref; do
  [[ -n $number ]] || continue
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
  --jq '.[] | select(.head.ref | startswith("autobump/")) | "\(.number)\t\(.head.ref)"')"

if [[ -n $existing_number ]]; then
  echo "::notice::the complete batch is already covered by open pull request #${existing_number}"
  echo "number=$existing_number" >>"$GITHUB_OUTPUT"
  echo "handled=true" >>"$GITHUB_OUTPUT"
else
  echo "handled=false" >>"$GITHUB_OUTPUT"
fi
