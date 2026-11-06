#!/usr/bin/env bash
set -euo pipefail

DESTINATION=${DESTINATION:-}
case "$DESTINATION" in
  production|testing) ;;
  *) echo "::error::Unsupported publication destination: $DESTINATION"; exit 1 ;;
esac
