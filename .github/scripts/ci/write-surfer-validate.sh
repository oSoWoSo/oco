#!/usr/bin/env bash
set -euo pipefail

: "${DESTINATION:?DESTINATION must be set}"
: "${RUNNER_TEMP:?RUNNER_TEMP must be set}"

if [[ ${1:-} == source ]]; then
  python3 extra/src/surfer-publish.py publication --destination "$DESTINATION"
  exit
fi

python3 validator/src/surfer-publish.py publication --destination "$DESTINATION" > "$RUNNER_TEMP/manifest.json"
outputs=$(python3 -c 'import json,os; d=json.load(open(os.environ["RUNNER_TEMP"]+"/manifest.json")); print("source_sha="+d["source_sha"]); print("source_run_id="+d["source_run_id"]); print("package_arches="+" ".join(d["package_arches"])); print("purge_packages="+" ".join(d["purge_packages"])); print("auto_detect_purge="+str(not d["package_arches"] and not d["result_arches"] and not d["purge_packages"] and not d["update_arch_pages"] and not d["update_feed"] and not d["update_main_index"]).lower()); print("update_arch_pages="+str(d["update_arch_pages"]).lower()); print("update_feed="+str(d["update_feed"]).lower()); print("update_main_index="+str(d["update_main_index"]).lower())')
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  printf '%s\n' "$outputs" >> "$GITHUB_OUTPUT"
else
  printf '%s\n' "$outputs"
fi
