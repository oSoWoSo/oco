#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
: "${PUBLICATION_DIR:?PUBLICATION_DIR must be set}"
: "${RUNNER_TEMP:?RUNNER_TEMP must be set}"

results="$RUNNER_TEMP/autobump-release-results"
rm -rf "$results"
mkdir -p "$results"
for result in "$PUBLICATION_DIR"/results/*.tsv; do
  [[ -f "$result" ]] || continue
  arch=${result##*/}
  arch=${arch%.tsv}
  mkdir -p "$results/build-results-$arch"
  cp "$result" "$results/build-results-$arch/results.tsv"
done
python3 src/close-update-issues.py "$results" --repo "$GITHUB_REPOSITORY" --token "$GH_TOKEN"
