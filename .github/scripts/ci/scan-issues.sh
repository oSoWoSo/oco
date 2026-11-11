#!/usr/bin/env bash
set -euo pipefail

workflow_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/workflows/scan.yml"

gh issue list --repo "$GITHUB_REPOSITORY" --state open \
  --label package-update --limit 1000 --json body,title >out/open-issues.json

while read -r pkg old new; do
  if jq -e --arg pkg "$pkg" --arg ver "$new" \
    --arg old "$old" \
    '.[] | (.body // "") as $body | (.title // "") as $title | select(($body | contains("<!-- package-update:" + $pkg + " -->") or contains("**Package:** `" + $pkg + "`")) and ($body | contains("<!-- upstream-version:" + $ver + " -->") or contains("**Upstream version:** `" + $ver + "`") or ($title | contains($pkg + " " + $old + " -> " + $ver))))' \
    out/open-issues.json >/dev/null; then
    echo "$pkg $new: matching issue already open"
    continue
  fi

  template_url="https://github.com/$GITHUB_REPOSITORY/blob/OCO/srcpkgs/$pkg/template"
  changelog_url=$(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*changelog[[:space:]]*=/ {
      sub(/^[^=]*=/, "")
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      if ($0 ~ /^"/) { sub(/^"/, ""); sub(/"[[:space:]]*(#.*)?$/, "") }
      else if ($0 ~ /^\047/) { sub(/^\047/, ""); sub(/\047[[:space:]]*(#.*)?$/, "") }
      else sub(/[[:space:]]+#.*/, "")
      print
      exit
    }
  ' "srcpkgs/$pkg/template")
  cat >out/issue.md <<EOF
**Package:** [\`$pkg\`]($template_url)
**Upstream version:** \`$new\`

<!-- package-update:$pkg -->
<!-- upstream-version:$new -->

A newer upstream release is available.
EOF
  if [ -n "$changelog_url" ]; then
    printf '\n**Release notes:** [%s](%s)\n' "$new" "$changelog_url" >>out/issue.md
  fi
  cat >>out/issue.md <<EOF

| Current | Latest |
|---|---|
| \`$old\` | \`$new\` |

Autobump opens a pull request for this automatically. Comment
\`nobump\` here to dismiss it.

_Opened by [\`scan.yml\`]($workflow_url)._
EOF

  issue=$(gh issue create \
    --repo "$GITHUB_REPOSITORY" \
    --title "$pkg $new" \
    --label package-update \
    --body-file out/issue.md)

  echo "$pkg -> ${issue:-FAILED}"
done <out/found
