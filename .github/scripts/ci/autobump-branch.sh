#!/usr/bin/env bash
set -euo pipefail

BRANCH="autobump/${TEMPLATE}-${VERSION}"
plan="$RUNNER_TEMP/autobump-plan.tsv"
snapshot="$RUNNER_TEMP/autobump-templates"

git config user.name "oSoWoSo-bot"
git config user.email "mail@osowoso.org"

# Keep the bumped templates aside: the branch is cut from the
# current OCO, so the bump has to be replayed onto it.
rm -rf "$snapshot"
mkdir -p "$snapshot"
while IFS=$'\t' read -r package _version _kind _order; do
  [[ -n $package ]] || continue
  mkdir -p "$snapshot/$package"
  cp "srcpkgs/$package/template" "$snapshot/$package/template"
done <"$plan"

git fetch --no-tags --depth=1 origin "+refs/heads/OCO:refs/remotes/origin/OCO"
git checkout -B "$BRANCH" refs/remotes/origin/OCO

# One commit per package, in dependency order, so the history
# reads like the build order and a reviewer can follow it.
while IFS=$'\t' read -r package version kind _order; do
  [[ -n $package ]] || continue
  tpl="srcpkgs/$package/template"
  cp "$snapshot/$package/template" "$tpl"
  git add "$tpl"
  if git diff --cached --quiet; then
    echo "::error::rebase onto OCO left ${tpl} unchanged; nothing to bump"
    exit 1
  fi
  if [[ $kind == version ]]; then
    git commit -m "$package $version"
  else
    git commit -m "$package: raise revision for updated dependencies"
  fi
done <"$plan"

./ocoman -u
git add README.md
if ! git diff --cached --quiet; then
  # The README is regenerated for the batch: amend it into the last
  # package commit instead of leaving a standalone "CI: update" commit.
  git commit --amend --no-edit
fi

git push --force "https://x-access-token:${OCO_TOKEN}@github.com/${GH_REPO}.git" "HEAD:${BRANCH}"

echo "VERSION=$VERSION" >>"$GITHUB_ENV"
echo "BRANCH=$BRANCH" >>"$GITHUB_ENV"
echo "branch=$BRANCH" >>"$GITHUB_OUTPUT"
