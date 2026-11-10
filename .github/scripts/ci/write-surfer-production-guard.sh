#!/usr/bin/env bash
set -euo pipefail

EVENT_NAME=${EVENT_NAME:-}
REF=${REF:-}
case "$EVENT_NAME:$REF" in
  push:refs/heads/OCO|workflow_dispatch:refs/heads/OCO|repository_dispatch:refs/heads/OCO|workflow_run:refs/heads/OCO) ;;
  *) echo "::error::Production writes are restricted to trusted OCO runs ($EVENT_NAME $REF)"; exit 1 ;;
esac
