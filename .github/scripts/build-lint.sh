#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/xbps/usr/bin/:$PATH"
packages="$PACKAGES"
cd /void-packages
failed=0

for template_name in $packages; do
  echo "==> Linting ${template_name}"
  if OUTPUT=$(sudo -Eu builder xlint "${template_name}" 2>&1); then
    LINT_RC=0
  else
    LINT_RC=$?
  fi
  if [ "$LINT_RC" -ne 0 ] || [ -n "$OUTPUT" ]; then
    failed=1
    echo "❌ ${template_name} lint failed:" >> $GITHUB_STEP_SUMMARY
    echo '```' >> $GITHUB_STEP_SUMMARY
    echo "${OUTPUT:-xlint exited with status $LINT_RC and produced no output}" >> $GITHUB_STEP_SUMMARY
    echo '```' >> $GITHUB_STEP_SUMMARY
    echo "❌ ${template_name} (exit $LINT_RC): ${OUTPUT:-no output}"
  else
    echo "✅ ${template_name} lint passed"
  fi
done
exit "$failed"
