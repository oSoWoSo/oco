#!/usr/bin/env bash
set -euo pipefail

prefix=${BRANCH_PREFIX:-autobump}
branch="$prefix/${PACK:-$TEMPLATE}"
open_prs=$(gh api --paginate --method GET "repos/${GH_REPO}/pulls" \
  -f state=open -f base="${BASE_REF:-OCO}" -F per_page=100 \
  --jq '.[] | select(.head.repo.full_name == .base.repo.full_name) | [.number, .head.sha, .user.login, .head.ref, .title] | @tsv')
existing=
while IFS= read -r row; do
  IFS=$'\t' read -r _number _sha _author ref _title <<<"$row"
  if [[ $ref == "$branch" ]]; then
    existing=$row
    break
  fi
  # Let in-flight member-named PRs finish on their original branch. New
  # batches use the canonical branch once the old PR is no longer open.
  if [[ -n ${PACK:-} && -z $existing && $ref == "$prefix/"* ]]; then
    member=${ref#*/}
    if [[ -f srcpkgs/$member/template && ! -L srcpkgs/$member &&
          $(python3 tools/autobump/autobump_packs.py "$member") == "$PACK" ]]; then
      existing=$row
    fi
  fi
done <<<"$open_prs"
if [[ -z $existing ]]; then
  echo 'handled=false' >>"$GITHUB_OUTPUT"
  exit 0
fi
IFS=$'\t' read -r number sha author ref title <<<"$existing"
if [[ ${AUTOMERGE:-false} == true && $author != oSoWoSo-bot ]]; then
  echo "::error::PR #${number} is owned by ${author}; close it before requesting a bot-created auto-merge PR"
  exit 1
fi

echo "number=$number" >>"$GITHUB_OUTPUT"
echo "branch=$ref" >>"$GITHUB_OUTPUT"
mapfile -t paths < <(awk -F '\t' '{print "srcpkgs/" $1 "/template"}' "$RUNNER_TEMP/autobump-plan.tsv" | LC_ALL=C sort)
files=$(gh api --paginate "repos/${GH_REPO}/pulls/${number}/files?per_page=100" \
  --jq '.[].filename')
templates=$(awk '/^srcpkgs\/[^/]+\/template$/' <<<"$files" | LC_ALL=C sort)
if [[ $templates == "$(printf '%s\n' "${paths[@]}")" ]]; then
  git fetch --no-tags --depth=1 origin "$sha"
  if git diff --quiet "$sha" -- "${paths[@]}"; then
    echo "::notice::no template changes since open PR #${number}; skipping push"
    echo 'handled=true' >>"$GITHUB_OUTPUT"
    if [[ -n ${PACK:-} && $title != "$PACK" ]]; then
      echo 'retitle=true' >>"$GITHUB_OUTPUT"
    fi
    exit 0
  fi
fi
echo 'handled=false' >>"$GITHUB_OUTPUT"
