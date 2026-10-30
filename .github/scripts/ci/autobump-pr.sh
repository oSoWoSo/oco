#!/usr/bin/env bash
set -euo pipefail

plan="$RUNNER_TEMP/autobump-plan.tsv"

printf '### Packages\n\n' >"$RUNNER_TEMP/pr-body.md"
printf '| package | change | version |\n|:-------|:-------|:-------|\n' \
  >>"$RUNNER_TEMP/pr-body.md"
while IFS=$'\t' read -r package version kind _order; do
  [[ -n $package ]] || continue
  template_url="https://github.com/${GH_REPO}/blob/${BRANCH}/srcpkgs/${package}/template"
  if [[ $kind == version ]]; then
    printf '| [`%s`](%s) | version | %s |\n' \
      "$package" "$template_url" "$version" >>"$RUNNER_TEMP/pr-body.md"
  else
    printf '| [`%s`](%s) | revision | unchanged |\n' \
      "$package" "$template_url" >>"$RUNNER_TEMP/pr-body.md"
  fi
done <"$plan"

printf '\n### Build order\n\n' >>"$RUNNER_TEMP/pr-body.md"
while IFS=$'\t' read -r package _version _kind order; do
  [[ -n $package ]] || continue
  printf '%s. `%s`\n' "$((order + 1))" "$package" >>"$RUNNER_TEMP/pr-body.md"
done <"$plan"

printf '\nThe revision-only bumps rebuild the packages that depend on a\n' \
  >>"$RUNNER_TEMP/pr-body.md"
printf 'changed package, so the repository stops serving binaries linked\n' \
  >>"$RUNNER_TEMP/pr-body.md"
printf 'against the old dependency.\n' >>"$RUNNER_TEMP/pr-body.md"

if [[ -n ${ISSUE_NUMBER:-} ]]; then
  printf '\nCloses #%s\n' "$ISSUE_NUMBER" >>"$RUNNER_TEMP/pr-body.md"
fi
printf '\n' >>"$RUNNER_TEMP/pr-body.md"
if [[ -s $RUNNER_TEMP/osv-report.md ]]; then
  cat "$RUNNER_TEMP/osv-report.md" >>"$RUNNER_TEMP/pr-body.md"
else
  printf '### OSV advisory check: error\n\n**ERROR:** Advisory report could not be generated; no clean result is implied.\n' \
    >>"$RUNNER_TEMP/pr-body.md"
fi

existing=$(gh api "repos/${GH_REPO}/pulls?state=open&per_page=100" \
  --jq ".[] | select(.head.ref == \"${BRANCH}\") | [.number, .user.login] | @tsv" |
  sed -n '1p')
if [[ -n $existing ]]; then
  IFS=$'\t' read -r existing_number existing_author <<<"$existing"
  if [[ ${AUTOMERGE:-false} == true && $existing_author != oSoWoSo-bot ]]; then
    echo "::error::PR #${existing_number} is owned by ${existing_author}; close it before requesting a bot-created auto-merge PR"
    exit 1
  fi
  echo "number=$existing_number" >>"$GITHUB_OUTPUT"
  echo "PR #${existing_number} already open by ${existing_author}"
  exit 0
fi

count=$(wc -l <"$plan")
title="${TEMPLATE} ${VERSION}"
if [[ $count -gt 1 ]]; then
  title="$title + $((count - 1)) more"
fi

number=$(gh api "repos/${GH_REPO}/pulls" \
  --method POST \
  -f title="$title" \
  -f head="$BRANCH" \
  -f base=OCO \
  -F body=@"$RUNNER_TEMP/pr-body.md" \
  --jq '.number')

echo "number=$number" >>"$GITHUB_OUTPUT"
echo "PR: #${number}"
