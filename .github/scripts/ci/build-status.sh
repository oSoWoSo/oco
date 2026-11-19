#!/usr/bin/env bash
# This job must run with always(): skipped dependencies are not success.
set -euo pipefail
fail() {
	echo "::error::$*"
	exit 1
}

[ "$DETECT_RESULT" = success ] || fail "Package detection: $DETECT_RESULT"
case "$SYNC_RESULT" in
success | skipped) ;;
*) fail "Testing base synchronization: $SYNC_RESULT" ;;
esac

if [ "$EVENT_NAME" = push ] && [ "$CURRENT_BRANCH" != OCO ] && [ "$SKIP_PUSH_PR" = true ]; then
	echo "Push build delegated to the open PR's build workflow"
	exit 0
fi

if [ -z "$PACKAGES" ]; then
	# PRs may change only workflow/docs files or remove a package. Pushes
	# and dispatches must build something (or process package removals).
	if [ "$EVENT_NAME" = pull_request ]; then
		echo "No buildable packages changed in this PR"
		exit 0
	fi
	[ -n "$REMOVED" ] || fail "No packages or removals detected; refusing a green build without work"
else
	[ "$LINT_RESULT" = success ] || fail "Template lint: $LINT_RESULT"
fi

[ "$BUILD_RESULT" = success ] || fail "Required build: $BUILD_RESULT (expected success)"
echo "Required builds passed"
