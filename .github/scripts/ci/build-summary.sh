#!/usr/bin/env bash
# Paste the lines that explain a failed build into the job summary, and when
# the run was triggered by a pull request, paste them into the PR as a
# comment. Runs only on failure; never fails the job on its own.
#
# Markers:
#   => ERROR:                   fatal xbps-src / build-loop error (grep -F
#                               also picks up the '==> ERROR:' variant)
#   => WARNING:                 non-fatal warning (stray path, private API)
#   UNKNOWN PKG PLEASE FIX!     SONAME with no owning package in common/shlibs
set -euo pipefail

BUILD_LOG="${BUILD_LOG:-}"
if [ -z "$BUILD_LOG" ] || [ ! -f "$BUILD_LOG" ]; then
        echo "::warning::BUILD_LOG is not set or unreadable; skipping build summary"
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

# Emit the marker lines, first-seen order, duplicates collapsed.
marker_lines() {
        for marker in '=> ERROR:' '=> WARNING:' 'UNKNOWN PKG PLEASE FIX!'; do
                lines="$(grep -F -- "$marker" "$BUILD_LOG" | strip_ts | dedup || true)"
                [ -n "$lines" ] || continue
                printf '%s\n' "$lines"
        done
}

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
                echo "## Build summary"
                echo
                marker_lines
        } >>"$GITHUB_STEP_SUMMARY"
fi

# Mirror the markers onto the PR that triggered the run, if any. Internally
# used by the autobump scripts to comment, so `gh` is available in the
# container. Best effort only.
if [ -n "${PR_NUMBER:-}" ]; then
        comment_file="$(mktemp)"
        marker_lines >"$comment_file"
        if [ -s "$comment_file" ] && command -v gh >/dev/null 2>&1 &&
                [ -n "${GH_REPO:-}" ] && [ -n "${GH_TOKEN:-}" ]; then
                gh api "repos/$GH_REPO/issues/$PR_NUMBER/comments" \
                        --method POST -F body=@"$comment_file" \
                        >/dev/null 2>&1 ||
                        echo "::warning::could not post build summary to PR #$PR_NUMBER"
        fi
        rm -f "$comment_file"
fi