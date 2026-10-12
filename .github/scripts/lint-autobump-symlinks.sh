#!/usr/bin/env bash
# Keep symlinks from src/autobump-pkgs
# Usage: lint-autobump-symlinks.sh [repo-root]
# Exit:  0 clean (warnings allowed), 1 on error.

set -uo pipefail

root=${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}
cd "$root" || exit 1

list=src/autobump-pkgs
errors=0
warnings=0

err() { printf 'error: %s\n' "$*" >&2; errors=$((errors + 1)); }
warn() { printf 'warning: %s\n' "$*" >&2; warnings=$((warnings + 1)); }

if [ ! -f "$list" ]; then
  err "$list not found"
  exit 1
fi

mapfile -t pkgs < <(grep -vE '^\s*(#|$)' "$list")
if [ "${#pkgs[@]}" -eq 0 ]; then
  err "$list lists no packages"
  exit 1
fi

declare -A seen_dir=()

for pkg in "${pkgs[@]}"; do
  path="srcpkgs/$pkg"

  if [ -L "$path" ]; then
    err "$path symlink to $(readlink "$path")"
    continue
  fi

  if [ ! -d "$path" ]; then
    err "$path not exist (listed in $list)"
    continue
  fi

  if [ ! -f "$path/template" ]; then
    err "$path no such template"
    continue
  fi

  # Two entries resolving to one directory means one bump file, two PRs.
  real=$(realpath "$path")
  if [ -n "${seen_dir[$real]:-}" ]; then
    err "$path and ${seen_dir[$real]} to the same dir ($real)"
  else
    seen_dir[$real]=$path
  fi
done

# Aliases that share a directory with an autobump package are the trap this
# whole check exists for: one keystroke in the whitelist bumps the wrong tree.
while read -r path; do
  [ -n "$path" ] || continue
  target=$(readlink "$path" 2>/dev/null) || continue
  real=$(realpath -m "$(dirname "$path")/$target")
  for dir in "${!seen_dir[@]}"; do
    if [ "$real" = "$dir" ]; then
      warn "$path -> $target shares a directory with autobump package ${seen_dir[$dir]}; never add it to $list"
    fi
  done
done < <(git ls-files -s srcpkgs | awk -F'\t' '$1 ~ /^120000/ { print $2 }')

printf 'checked %d package(s) from %s: %d error(s), %d warning(s)\n' \
  "${#pkgs[@]}" "$list" "$errors" "$warnings"

[ "$errors" -eq 0 ]
