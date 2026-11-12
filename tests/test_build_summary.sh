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
grep -q '^## Build summary$' "$summary" || { echo "FAIL: missing header"; exit 1; }
[ "$(grep -Fc '=> ERROR: foo-1.0_1: do_check:' "$summary")" -eq 1 ] || { echo "FAIL: duplicate ERROR line not deduped"; exit 1; }
[ "$(grep -c '^###' "$summary")" -eq 0 ] || { echo "FAIL: section headers present"; exit 1; }
grep -q '^=> WARNING: usr/lib/cmake should be in -devel package$' "$summary" || { echo "FAIL: WARNING line missing"; exit 1; }
grep -q 'SONAME: libonig.so.5 <-> UNKNOWN PKG PLEASE FIX!' "$summary" || { echo "FAIL: UNKNOWN PKG line missing"; exit 1; }

# A log with no marker produces a header but no sections.
printf '==> Building bar\nno marks here\n' >"$log"
rm -f "$summary"
run_summary
grep -q '^## Build summary$' "$summary" || { echo "FAIL: header missing on clean log"; exit 1; }
[ "$(grep -c '^###' "$summary")" -eq 0 ] || { echo "FAIL: sections present for clean log"; exit 1; }

# Missing inputs don't fail the job. The summary file is optional (the PR
# comment may still be posted), so only an absent/unreadable BUILD_LOG warns.
rm -f "$summary"
unset GITHUB_STEP_SUMMARY
out=$(BUILD_LOG="$log" bash "$SUMMARY_SH" 2>&1)
echo "$out" | grep -q 'GITHUB_STEP_SUMMARY' && { echo "FAIL: unexpected summary warning"; exit 1; }
[ ! -f "$summary" ] || { echo "FAIL: summary written without GITHUB_STEP_SUMMARY"; exit 1; }

rm -f "$summary"
out=$(GITHUB_STEP_SUMMARY="$summary" bash "$SUMMARY_SH" 2>&1)
echo "$out" | grep -q 'BUILD_LOG is not set' || { echo "FAIL: no warning on missing BUILD_LOG"; exit 1; }

# When the run was triggered by a PR, the markers are posted as a comment via
# `gh` (best effort). Re-seed the log with markers first.
cat >"$log" <<'EOF'
=> ERROR: bar-1.0_1: do_check: '...' exited with 8
=> WARNING: usr/lib/cmake should be in -devel package
EOF
fake_gh="$TMP_DIR/gh"
cat >"$fake_gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >>"$GH_FAKE_LOG"
if [ "$1" = "api" ] && [ "$3" = "comments" ]; then
        cat "$5"
fi
exit 0
EOF
chmod +x "$fake_gh"

GH_FAKE_LOG="$TMP_DIR/gh-args"
export GH_FAKE_LOG
rm -f "$GH_FAKE_LOG" "$summary"
PATH="$TMP_DIR:$PATH" PR_NUMBER=42 GH_REPO=oSoWoSo/oco GH_TOKEN=t \
        BUILD_LOG="$log" GITHUB_STEP_SUMMARY="$summary" bash "$SUMMARY_SH"
grep -q 'repos/oSoWoSo/oco/issues/42/comments' "$GH_FAKE_LOG" || { echo "FAIL: no PR comment posted"; exit 1; }

# Without PR_NUMBER no `gh` call is made even when the token is present.
rm -f "$GH_FAKE_LOG" "$summary"
PATH="$TMP_DIR:$PATH" GH_REPO=oSoWoSo/oco GH_TOKEN=t \
        BUILD_LOG="$log" GITHUB_STEP_SUMMARY="$summary" bash "$SUMMARY_SH"
[ ! -f "$GH_FAKE_LOG" ] || { echo "FAIL: gh called without PR_NUMBER"; exit 1; }

echo "build-summary.sh: ok"
