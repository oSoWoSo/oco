#!/usr/bin/env bash
set -euo pipefail
echo "==> Merging free + nonfree"
[ -d nonfree ] && mv nonfree/*.xbps . 2>/dev/null || true
: "${ARCH:?ARCH must be set}"
out="$RUNNER_TEMP/packages/$ARCH"
mkdir -p "$out"
for pkg in ./*.xbps; do
  [ -f "$pkg" ] || continue
  base=$(basename "$pkg")
  grep -qxF "$base" /tmp/pre-build-pkgs.txt && continue
  cp "$pkg" "$out/"
done
