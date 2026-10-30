#!/usr/bin/env bash
set -euo pipefail

if [[ -n ${PR_NUMBER:-} ]]; then
  if [[ -z ${REQUEST_VER:-} ]]; then
    REQUEST_VER=$VERSION
  fi
  [[ -n $REQUEST_VER ]] || { echo "::error::cannot determine version for done marker"; exit 1; }

  {
    printf 'PR opened: **%s** -> #%s.\n\n' "$TEMPLATE" "$PR_NUMBER"
    printf 'This pull request covers the whole dependency component of `%s`:\n\n' "$TEMPLATE"
    while IFS=$'\t' read -r package version kind _order; do
      [[ -n $package ]] || continue
      if [[ $kind == version ]]; then
        printf -- '- `%s` -> %s\n' "$package" "$version"
      else
        printf -- '- `%s` (revision bump)\n' "$package"
      fi
    done <"$RUNNER_TEMP/autobump-plan.tsv"
    printf '\n<!-- autobump:done for %s -->\n' "$REQUEST_VER"
  } >"$RUNNER_TEMP/comment.md"

  gh api "repos/${GH_REPO}/issues/${ISSUE_NUMBER}/comments" \
    --method POST -F body=@"$RUNNER_TEMP/comment.md" || true
fi
