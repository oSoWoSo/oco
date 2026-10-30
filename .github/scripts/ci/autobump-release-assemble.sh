#!/usr/bin/env bash
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP must be set}"
: "${MERGE_SHA:?MERGE_SHA must be set}"
: "${RUN_ID:?RUN_ID must be set}"

root="$RUNNER_TEMP/surfer-publication"
staging="$RUNNER_TEMP/autobump-staging"
rm -rf "$root"
mkdir -p "$root/packages" "$root/results"

for arch in x86_64 x86_64-musl aarch64 aarch64-musl; do
  source="$staging/$arch"
  [[ -d "$source" ]] || continue
  mkdir -p "$root/packages/$arch"
  cp "$source"/*."$arch".xbps "$root/packages/$arch/"
done

for result in "$staging"/results/build-results-*; do
  [[ -d "$result" ]] || continue
  arch=${result##*build-results-}
  cp "$result/results.tsv" "$root/results/$arch.tsv"
done

python3 - "$root" <<'PY'
import json, os, pathlib, sys

root = pathlib.Path(sys.argv[1])
arches = sorted(p.name for p in (root / "packages").iterdir() if p.is_dir())
results = sorted(p.stem for p in (root / "results").glob("*.tsv"))
data = {"schema_version": 1, "destination": "production", "source_sha": os.environ["MERGE_SHA"], "source_run_id": os.environ["RUN_ID"], "package_arches": arches, "result_arches": results, "purge_packages": [], "update_arch_pages": True, "update_feed": True, "update_main_index": False}
(root / "manifest.json").write_text(json.dumps(data) + "\n")
PY
