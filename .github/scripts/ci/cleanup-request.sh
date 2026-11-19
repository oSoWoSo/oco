#!/usr/bin/env bash
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP must be set}"
: "${PREFIX?PREFIX must be set (empty for production)}"
: "${SHA:?SHA must be set}"
: "${RUN_ID:?RUN_ID must be set}"
: "${PACKAGES?PACKAGES must be set (empty for automatic cleanup)}"

case "$PREFIX" in
  '') destination=production ;;
  testing) destination=testing ;;
  *) echo "::error::Unsupported repository prefix"; exit 1 ;;
esac

python3 src/surfer-publish.py "$RUNNER_TEMP/surfer-publication" --create \
  --destination "$destination" --source-sha "$SHA" --source-run-id "$RUN_ID" \
  --purge-packages "$PACKAGES"
