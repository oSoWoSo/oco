#!/usr/bin/env bash
set -euo pipefail

handled=false

members=$(sed -n '/^<!-- pack-member:.* -->$/p' <<<"${ISSUE_BODY:-}")
if [[ -n $members ]]; then
  # A new member or version invalidates the old handled marker.
  digest=$(printf '%s\n' "$members" | LC_ALL=C sort | sha256sum)
  request_ver="pack-${digest%% *}"
else
  request_ver=$(printf '%s\n' "${ISSUE_BODY:-}" |
    sed -n 's|.*<!-- upstream-version:\([^>]*\) -->.*|\1|p' | sed -n '1p')
  [[ -n $request_ver ]] || request_ver=$(printf '%s\n' "${ISSUE_BODY:-}" |
    sed -n 's|.*\*\*Upstream version:\*\*[^`]*`\([^`]*\)`.*|\1|p' | sed -n '1p')
fi
echo "request_ver=$request_ver" >>"$GITHUB_OUTPUT"

if [[ -n ${ISSUE_BODY:-} ]] && printf '%s\n' "$ISSUE_BODY" | grep -q '<!-- autobump:no -->'; then
  echo "Feed-only issue ($TEMPLATE is in config/autobump-blacklist): nothing to do"
  echo "handled=true" >>"$GITHUB_OUTPUT"
  exit 0
fi

if [[ -n ${ISSUE_NUMBER:-} && -z $request_ver ]]; then
  echo "::error::package-update issue is missing an upstream version marker/heading"
  exit 1
fi

if [[ -n ${ISSUE_NUMBER:-} ]]; then
  comments=$(gh api "repos/${GH_REPO}/issues/${ISSUE_NUMBER}/comments?per_page=100" \
    --jq '.[] | select(.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR") | .body')

  if printf '%s\n' "$comments" | grep -qiE '^> *nobump *$|^nobump *$'; then
    echo "Issue dismissed with a nobump comment"
    handled=true
  elif [[ -n $request_ver ]] &&
    { printf '%s\n' "$comments" | grep -qF "<!-- autobump:skip for $request_ver -->" ||
      printf '%s\n' "$comments" | grep -qF "<!-- autobump:done for $request_ver -->"; }
  then
    echo "Already handled for $request_ver: skipping"
    handled=true
  fi
fi

echo "handled=$handled" >>"$GITHUB_OUTPUT"
