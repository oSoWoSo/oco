#!/usr/bin/env bash
# Paste the lines that explain a failed build into the job summary.
#
# Intended for the x86_64 matrix job of the build workflow: the log of the
# failed "Build packages" step is saved to $BUILD_LOG (via tee) and the
# relevant markers are extracted here. Runs only on failure; never fails the
# job on its own.
#
# Markers:
#   => ERROR:                   fatal xbps-src / build-loop error (grep -F
#                               also picks up the '==> ERROR:' variant)
#   => WARNING:                 non-fatal warning (stray path, private API)
#   UNKNOWN PKG PLEASE FIX!     SONAME with no owning package in common/shlibs
set -euo pipefail

BUILD_LOG="${BUILD_LOG:-}"
if [ -z "$BUILD_LOG" ]; then
        echo "::warning::BUILD_LOG is not set; skipping build summary"
        exit 0
fi
if [ ! -f "$BUILD_LOG" ]; then
        echo "::warning::build log not found: $BUILD_LOG; skipping build summary"
        exit 0
fi

SUMMARY="${GITHUB_STEP_SUMMARY:-}"
if [ -z "$SUMMARY" ]; then
        echo "::warning::GITHUB_STEP_SUMMARY is not set; skipping build summary"
        exit 0
fi

# GitHub Actions renders each captured line with an ISO-8601 timestamp when it
# stores/downloads logs, but the file produced by `tee` during the run has raw
# lines. Strip a leading timestamp defensively so both shapes classify as
# markers.
strip_ts() {
        sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z //'
}

# Keep first-seen order while dropping exact duplicates.
dedup() {
        awk '!seen[$0]++'
}

{
        echo "## Build summary"
        echo
        for marker in '=> ERROR:' '=> WARNING:' 'UNKNOWN PKG PLEASE FIX!'; do
                lines="$(grep -F -- "$marker" "$BUILD_LOG" | strip_ts | dedup || true)"
                [ -n "$lines" ] || continue
                echo "### \`$marker\`"
                echo
                printf '%s\n' "$lines" | sed 's/^/    /'
                echo
        done
} >>"$SUMMARY"