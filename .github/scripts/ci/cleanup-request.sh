#!/usr/bin/env bash
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP must be set}"
: "${PREFIX:?PREFIX must be set}"
: "${SHA:?SHA must be set}"
: "${RUN_ID:?RUN_ID must be set}"
: "${PACKAGES:?PACKAGES must be set (use an empty value when there are no packages)}"

case "$PREFIX" in
  '') destination=production ;;
  testing) destination=testing ;;
  *) echo "::error::Unsupported repository prefix"; exit 1 ;;
esac

mkdir -p "$RUNNER_TEMP/surfer-publication"
python3 - "$RUNNER_TEMP/surfer-publication" "$destination" "$SHA" "$RUN_ID" "$PACKAGES" <<'PY'
import json, pathlib, sys

root = pathlib.Path(sys.argv[1])
packages = sys.argv[5].split()
manifest = {
    "schema_version": 1,
    "destination": sys.argv[2],
    "source_sha": sys.argv[3],
    "source_run_id": sys.argv[4],
    "package_arches": [],
    "result_arches": [],
    "purge_packages": packages,
    "update_arch_pages": False,
    "update_feed": False,
    "update_main_index": False,
}
manifest_path = root / "manifest.json"
try:
    existing = json.loads(manifest_path.read_text())
except (OSError, ValueError):
    existing = None

if existing != manifest:
    manifest_path.write_text(json.dumps(manifest) + "\n")
    purge_path = root / "purge-packages.txt"
    if packages:
        purge_path.write_text("\n".join(packages) + "\n")
    else:
        purge_path.unlink(missing_ok=True)
PY
