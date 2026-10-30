#!/usr/bin/env bash
set -euo pipefail

if [[ ${FORCE:-false} == true ]] || grep -qxF "$TEMPLATE" src/autobump-pkgs; then
  echo "in_list=true" >>"$GITHUB_OUTPUT"
  exit 0
fi

echo "in_list=false" >>"$GITHUB_OUTPUT"

if [[ -n ${ISSUE_NUMBER:-} && -z ${REQUEST_VER:-} ]]; then
  echo "::error::cannot post a version-scoped skip marker without REQUEST_VER"
  exit 1
fi
