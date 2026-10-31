#!/usr/bin/env bash
set -euo pipefail

# A template may be bumped automatically unless it is listed in
# src/autobump-blacklist or is a symlink alias: aliases share a real
# package's tree and never carry their own update file or distfiles.

if [[ ${FORCE:-false} == true ]] \
  || { [ ! -L "srcpkgs/$TEMPLATE" ] && ! grep -qxF "$TEMPLATE" src/autobump-blacklist; }; then
  echo "in_list=true" >>"$GITHUB_OUTPUT"
  exit 0
fi

echo "in_list=false" >>"$GITHUB_OUTPUT"

if [[ -n ${ISSUE_NUMBER:-} && -z ${REQUEST_VER:-} ]]; then
  echo "::error::cannot post a version-scoped skip marker without REQUEST_VER"
  exit 1
fi
