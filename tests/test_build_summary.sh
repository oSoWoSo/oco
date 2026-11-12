#!/bin/sh
# Tests for .github/scripts/ci/build-summary.sh: pastes the failure markers
# from a saved x86_64 build log into the GitHub step summary. Aligned with
# the other helper tests run from tests/run.sh.

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
SUMMARY_SH="$SCRIPT_DIR/.github/scripts/ci/build-summary.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

log="$TMP_DIR/build-log"
summary="$TMP_DIR/summary.md"

run_summary() {
        BUILD_LOG="$log" GITHUB_STEP_SUMMARY="$summary" bash "$SUMMARY_SH"
}

# --- sample log ----------------------------------------------------------

cat >"$log" <<'EOF'
=> foo-1.0_1: running do_check ...
=> ERROR: foo-1.0_1: do_check: '...' exited with 8
=> ERROR:   in do_check() at common/build-style/cmake.sh:141
=> WARNING: usr/lib/cmake should be in -devel package
   SONAME: libonig.so.5 <-> UNKNOWN PKG PLEASE FIX!
=> ERROR: foo-1.0_1: do_check: '...' exited with 8
EOF

run_summary

# The summary keeps first-seen order and drops duplicate marks.
grep -q '^### `=> ERROR:`$' "$summary" || { echo "FAIL: missing ERROR section"; exit 1; }
[ "$(grep -Fc '=> ERROR: foo-1.0_1: do_check:' "$summary")" -eq 1 ] || { echo "FAIL: duplicate ERROR line not deduped"; exit 1; }
grep -q '^### `=> WARNING:`$' "$summary" || { echo "FAIL: missing WARNING section"; exit 1; }
grep -q '^### `UNKNOWN PKG PLEASE FIX!`$' "$summary" || { echo "FAIL: missing UNKNOWN PKG section"; exit 1; }
grep -q '^    => ERROR: foo-1.0_1: do_check' "$summary" || { echo "FAIL: ERROR line not indented"; exit 1; }

# A log with no marker produces a header but no sections.
printf '==> Building bar\nno marks here\n' >"$log"
rm -f "$summary"
run_summary
grep -q '^## Build summary$' "$summary" || { echo "FAIL: header missing on clean log"; exit 1; }
[ "$(grep -c '^###' "$summary")" -eq 0 ] || { echo "FAIL: sections present for clean log"; exit 1; }

# Keep the script silent on success but surface a warning when a required
# input is missing.
rm -f "$summary"
unset GITHUB_STEP_SUMMARY
out=$(BUILD_LOG="$log" bash "$SUMMARY_SH" 2>&1)
echo "$out" | grep -q 'GITHUB_STEP_SUMMARY' || { echo "FAIL: no warning on missing summary file"; exit 1; }

rm -f "$summary"
out=$(GITHUB_STEP_SUMMARY="$summary" bash "$SUMMARY_SH" 2>&1)
echo "$out" | grep -q 'BUILD_LOG is not set' || { echo "FAIL: no warning on missing BUILD_LOG"; exit 1; }

echo "build-summary.sh: ok"