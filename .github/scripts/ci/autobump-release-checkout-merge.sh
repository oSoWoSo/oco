#!/usr/bin/env bash
set -euo pipefail

: "${CHECKOUT_DIR:?CHECKOUT_DIR must be set}"
: "${MERGE_SHA:?MERGE_SHA must be set}"

git -C "$CHECKOUT_DIR" fetch --no-tags origin "$MERGE_SHA"
git -C "$CHECKOUT_DIR" checkout --detach "$MERGE_SHA"
