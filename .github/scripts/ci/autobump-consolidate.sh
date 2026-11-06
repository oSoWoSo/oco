#!/usr/bin/env bash
set -euo pipefail

plan="$RUNNER_TEMP/autobump-plan.tsv"
while IFS=$'\t' read -r number _ref; do
  [[ -n $number ]] || continue
  [[ $number != "$BATCH_PR" ]] || continue
  files=$(gh api "repos/${GH_REPO}/pulls/${number}/files?per_page=100" \
    --jq '.[].filename')
  templates=$(printf '%s\n' "$files" | grep -E '^srcpkgs/[^/]+/template$' || true)
  [[ -n $templates ]] || continue

  belongs=true
  overlap=false
  while IFS= read -r filename; do
    package=${filename#srcpkgs/}
    package=${package%/template}
    if awk -F '\t' -v pkg="$package" '$1 == pkg { found=1 } END { exit !found }' "$plan"; then
      overlap=true
    else
      belongs=false
    fi
  done <<<"$templates"

  if [[ $belongs == true && $overlap == true ]]; then
    gh pr comment "$number" --repo "$GH_REPO" --body \
      "This package update is included in the dependency batch PR #${BATCH_PR}; closing this individual autobump PR."
    gh api "repos/${GH_REPO}/pulls/${number}" \
      --method PATCH -f state=closed >/dev/null
    echo "Closed superseded autobump PR #${number}"
  fi
done <<<"$(gh api "repos/${GH_REPO}/pulls?state=open&per_page=100" \
  --jq '.[] | select(.head.ref | startswith("autobump/")) | "\(.number)\t\(.head.ref)"')"
