#!/usr/bin/env bash
set -euo pipefail

.github/scripts/autobump-batch.py apply --plan "$RUNNER_TEMP/autobump-plan.tsv"

version=$(sed -n 's|^version=||p' "srcpkgs/$TEMPLATE/template" | head -1 | tr -d '"')
echo "version=$version" >>"$GITHUB_OUTPUT"
echo "bumped=true" >>"$GITHUB_OUTPUT"
