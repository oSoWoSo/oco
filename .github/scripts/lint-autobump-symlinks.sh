#!/usr/bin/env bash
# Keep symlink aliases out of src/autobump-blacklist.
# Aliases are forbidden from autobump automatically, so listing one here is
# redundant and listing it instead of its real target would silently exclude
# the wrong package.
# Usage: lint-autobump-symlinks.sh [repo-root]
# Exit:  0 clean, 1 on error.

set -uo pipefail

root=${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}
cd "$root" || exit 1

list=src/autobump-blacklist
errors=0

err() { printf 'error: %s\n' "$*" >&2; errors=$((errors + 1)); }

if [ ! -f "$list" ]; then
  err "$list not found"
  exit 1
fi

mapfile -t pkgs < <(grep -vE '^\s*(#|$)' "$list")

for pkg in "${pkgs[@]}"; do
  path="srcpkgs/$pkg"

  if [ -L "$path" ]; then
    err "$path is a symlink to $(readlink "$path"); aliases are already excluded from autobump"
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
done

printf 'checked %d package(s) from %s: %d error(s)\n' \
  "${#pkgs[@]}" "$list" "$errors"

[ "$errors" -eq 0 ]
