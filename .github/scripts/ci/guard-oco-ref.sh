#!/usr/bin/env bash
set -euo pipefail

: "${REF:?REF must be set}"
test "$REF" = refs/heads/OCO || { echo "::error::Production cleanup is only allowed on OCO (got: $REF)"; exit 1; }
