#!/usr/bin/env bash
set -euo pipefail

git config user.name "oSoWoSo-bot"
git config user.email "mail@osowoso.org"
git add .gitignore README.md .github/workflows/build.yml Manual.md
if ! git diff --cached --quiet; then
  git commit -m "CI: update"
  git push
fi

source_sha=$(git rev-parse HEAD)
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  echo "source_sha=$source_sha" >> "$GITHUB_OUTPUT"
else
  echo "source_sha=$source_sha"
fi

publication_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/surfer-publication"
run_id="${RUN_ID:-0}"
mkdir -p "$publication_dir"
python3 - "$publication_dir/manifest.json" "$source_sha" "$run_id" <<'PY'
import json, sys

json.dump({"schema_version": 1, "destination": "production", "source_sha": sys.argv[2], "source_run_id": sys.argv[3], "package_arches": [], "result_arches": [], "purge_packages": [], "update_arch_pages": False, "update_feed": False, "update_main_index": True}, open(sys.argv[1], "w"))
PY
