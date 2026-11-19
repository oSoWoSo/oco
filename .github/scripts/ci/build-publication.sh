#!/usr/bin/env bash
# Assemble ordinary build artifacts using the shared publication contract.
set -euo pipefail
: "${RUNNER_TEMP:?}" "${DESTINATION:?}" "${SOURCE_SHA:?}" "${SOURCE_RUN_ID:?}"
root="$RUNNER_TEMP/surfer-publication"
mkdir -p "$root/packages" "$root/results"
for dir in "$RUNNER_TEMP"/incoming/build-packages-*; do
  [[ -d "$dir" ]] || continue
  arch=${dir##*build-packages-}
  mkdir -p "$root/packages/$arch"
  cp "$dir"/*.xbps "$root/packages/$arch/" 2>/dev/null || rmdir "$root/packages/$arch"
done
for dir in "$RUNNER_TEMP"/incoming/build-results-*; do
  [[ -d "$dir" ]] || continue
  arch=${dir##*build-results-}
  [[ -f "$dir/results.tsv" ]] && cp "$dir/results.tsv" "$root/results/$arch.tsv"
done
flags=(--update-arch-pages)
# Removal-only requests have no build results and must not request a feed update.
compgen -G "$root/results/*.tsv" >/dev/null && flags+=(--update-feed)
[[ "$DESTINATION" != testing ]] || flags+=(--update-main-index)
python3 src/surfer-publish.py "$root" --create --destination "$DESTINATION" \
  --source-sha "$SOURCE_SHA" --source-run-id "$SOURCE_RUN_ID" \
  --purge-packages "${REMOVED:-}" "${flags[@]}"
