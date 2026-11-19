#!/usr/bin/env bash
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP must be set}"
: "${MERGE_SHA:?MERGE_SHA must be set}"
: "${RUN_ID:?RUN_ID must be set}"

root="$RUNNER_TEMP/surfer-publication"
staging="$RUNNER_TEMP/autobump-staging"
rm -rf "$root"
mkdir -p "$root/packages" "$root/results"

for arch in x86_64 x86_64-musl aarch64 aarch64-musl; do
  source="$staging/$arch"
  [[ -d "$source" ]] || continue
  mkdir -p "$root/packages/$arch"
  cp "$source"/*."$arch".xbps "$root/packages/$arch/"
done

for result in "$staging"/results/build-results-*; do
  [[ -d "$result" ]] || continue
  arch=${result##*build-results-}
  cp "$result/results.tsv" "$root/results/$arch.tsv"
done

python3 extra/tools/repository/surfer-publish.py "$root" --create --destination production \
  --source-sha "$MERGE_SHA" --source-run-id "$RUN_ID" \
  --update-arch-pages --update-feed
