#!/usr/bin/env bash
set -euo pipefail

if [[ -n ${INPUT_PKG:-} ]]; then
  PKG=$INPUT_PKG
else
  PKG=$(printf '%s\n' "${ISSUE_BODY:-}" |
    sed -n 's|.*\*\*Package:\*\*[^`]*`\([^`]*\)`.*|\1|p' |
    sed -n '1p')
  [[ -n $PKG ]] || PKG=$(printf '%s\n' "${ISSUE_BODY:-}" |
    sed -n 's|.*<!-- package-update:\([^>]*\) -->.*|\1|p' |
    sed -n '1p')
  PKG=$(printf '%s' "$PKG" | tr -d '[:space:]')
  [[ -n $PKG ]] || {
    echo "::error::could not extract package name from issue body"
    exit 1
  }
fi

found=$(find srcpkgs -maxdepth 1 -mindepth 1 -type d -iname "$PKG" -printf '%f\n' | head -1)
[[ -n $found ]] || {
  echo "::error::template not found in srcpkgs: $PKG"
  exit 1
}

if [[ -L "srcpkgs/$found" ]]; then
  echo "::error::srcpkgs/$found is a symlinked alias, refusing to bump it"
  exit 1
fi

echo "TEMPLATE=$found" >>"$GITHUB_ENV"
echo "template=$found" >>"$GITHUB_OUTPUT"
