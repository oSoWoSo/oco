#!/usr/bin/env bash
set -euo pipefail

mkdir -p out

mapfile -t pkgs < <(
  grep -vE '^\s*(#|$)' src/autobump-pkgs
)

if [ -n "$SCAN_PKG" ]; then
  pkgs=("$SCAN_PKG")
fi

echo "Scanning ${#pkgs[@]} template(s)"

for pkg in "${pkgs[@]}"; do
  if [ -L "srcpkgs/$pkg" ]; then
    echo "::notice::$pkg is a symlinked alias, skipping"
    continue
  fi

  if ! out=$(.github/scripts/detect-update.sh "$pkg" "$GITHUB_WORKSPACE"); then
    echo "::warning::$pkg: detection failed, skipping"
    continue
  fi

  if [ -z "$out" ]; then
    echo "$pkg: up to date"
    continue
  fi

  # "<pkg> <old> <new>"
  read -r name old new <<<"$out"
  echo "$name $old $new" >>out/found
  echo "$name: $old -> $new"
done

if [ ! -s out/found ]; then
  echo "Nothing to bump."
  exit 0
fi

echo "count=$(wc -l <out/found)" >>"$GITHUB_OUTPUT"
