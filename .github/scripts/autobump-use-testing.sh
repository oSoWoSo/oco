#!/usr/bin/env bash
set -euo pipefail

# Use the workflow's helpers with the testing branch's package inputs.
# testing can still use the layout from before the tooling migration.
git fetch --no-tags --depth=1 origin refs/heads/testing
git restore --source=FETCH_HEAD --staged --worktree -- srcpkgs shlibs_append shlibs_remove
for file in autobump-packs.tsv autobump-dependencies.tsv autobump-blacklist; do
  path="config/$file"
  if ! git cat-file -e "FETCH_HEAD:$path" 2>/dev/null; then
    if [[ $file == autobump-blacklist ]]; then
      path="src/$file"
    else
      path=".github/$file"
    fi
  fi
  git show "FETCH_HEAD:$path" >"config/$file"
done
