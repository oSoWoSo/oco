#!/usr/bin/env bash
set -euo pipefail

requested_pack=$(sed -n 's/^<!-- pack-update:\([A-Za-z0-9+._-]*\) -->$/\1/p' <<<"${ISSUE_BODY:-}")
if [[ -n ${INPUT_PKG:-} ]]; then
  PKG=$INPUT_PKG
elif [[ -n $requested_pack ]]; then
  PKG=
  while read -r member; do
    if [[ -f srcpkgs/$member/template && ! -L srcpkgs/$member ]] &&
        ! grep -qxF "$member" config/autobump-blacklist; then
      PKG=$member
      break
    fi
  done < <(sed -n 's/^<!-- pack-member:\([A-Za-z0-9+._-]*\) [A-Za-z0-9._+~-]* -->$/\1/p' <<<"$ISSUE_BODY")
else
  PKG=$(printf '%s\n' "${ISSUE_BODY:-}" |
    sed -n 's|.*\*\*Package:\*\*[^`]*`\([^`]*\)`.*|\1|p' |
    sed -n '1p')
  [[ -n $PKG ]] || PKG=$(printf '%s\n' "${ISSUE_BODY:-}" |
    sed -n 's|.*<!-- package-update:\([^>]*\) -->.*|\1|p' |
    sed -n '1p')
  PKG=$(printf '%s' "$PKG" | tr -d '[:space:]')
fi

[[ $PKG =~ ^[A-Za-z0-9][A-Za-z0-9+._-]*$ ]] || {
  echo "::error::could not find a valid package name in the bump request"
  exit 1
}
found=$(find srcpkgs -maxdepth 1 -mindepth 1 -type d -iname "$PKG" -printf '%f\n' | sed -n '1p')
[[ -n $found ]] || {
  echo "::error::template not found in srcpkgs: $PKG"
  exit 1
}

if [[ -L "srcpkgs/$found" ]]; then
  echo "::error::srcpkgs/$found is a symlinked alias, refusing to bump it"
  exit 1
fi

pack=$(python3 tools/autobump/autobump_packs.py "$found")
if [[ -n $requested_pack && $requested_pack != "$pack" ]]; then
  echo "::error::requested pack does not match the configured pack for $found"
  exit 1
fi
{
  echo "template=$found"
  echo "pack=$pack"
  echo "target=${pack:-$found}"
} >>"$GITHUB_OUTPUT"
