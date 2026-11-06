#!/usr/bin/env bash
set -euo pipefail

: "${DESTINATION:?DESTINATION must be set}"
ARCHES=${ARCHES:-}
PURGES=${PURGES:-}
AUTO_DETECT_PURGE=${AUTO_DETECT_PURGE:-false}

export PATH="/opt/xbps/usr/bin:$PATH"
case "$DESTINATION" in production) export SURF_PATH_PREFIX='' ;; testing) export SURF_PATH_PREFIX=testing ;; esac
export SURF_PURGE_PACKAGES="$PURGES"
. extra/src/oco-key.sh
oco_key_write /tmp/private.pem
for arch in $ARCHES; do
  export ARCH="$arch" XBPS_ARCH="$arch" XBPS_TARGET_ARCH="$arch"
  dir="$GITHUB_WORKSPACE/publication/packages/$arch"
  xbps-rindex -S --privkey /tmp/private.pem "$dir"/*.xbps
  (cd extra && BUILDDIR="$dir" ./ocoman -p)
done
if [[ -n $PURGES || $AUTO_DETECT_PURGE == true ]]; then
  mkdir -p "$RUNNER_TEMP/empty"
  export SURF_PURGE_PACKAGES="$PURGES"
  for arch in x86_64 x86_64-musl aarch64 aarch64-musl; do
    export ARCH="$arch" XBPS_ARCH="$arch" XBPS_TARGET_ARCH="$arch"
    (cd extra && BUILDDIR="$RUNNER_TEMP/empty" ./ocoman -p)
  done
fi
