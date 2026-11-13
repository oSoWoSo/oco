#!/usr/bin/env bash
set -euo pipefail

BRANCH="autobump/${TEMPLATE}-${VERSION}"
plan="$RUNNER_TEMP/autobump-plan.tsv"
snapshot="$RUNNER_TEMP/autobump-templates"
manifest_snapshot="$RUNNER_TEMP/autobump-dependencies.tsv"
manifest=".github/autobump-dependencies.tsv"

git config user.name "oSoWoSo-bot"
git config user.email "mail@osowoso.org"

# Keep the bumped templates aside: the branch is cut from the
# current OCO, so the bump has to be replayed onto it.
rm -rf "$snapshot"
rm -f "$manifest_snapshot"
mkdir -p "$snapshot"
while IFS=$'\t' read -r package _version _kind _order; do
	[[ -n $package ]] || continue
	mkdir -p "$snapshot/$package"
	cp "srcpkgs/$package/template" "$snapshot/$package/template"
done <"$plan"
if [[ -f $manifest ]]; then
	mv "$manifest" "$manifest_snapshot"
fi

git fetch --no-tags --depth=1 origin "+refs/heads/OCO:refs/remotes/origin/OCO"
git checkout -B "$BRANCH" refs/remotes/origin/OCO
if [[ -f $manifest_snapshot ]]; then
	mkdir -p "$(dirname "$manifest")"
	cp "$manifest_snapshot" "$manifest"
fi

# Commit the plan's package sequence so reviewers can follow the batch.
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
if [[ -f $manifest_snapshot && -f $manifest ]]; then
	python3 - "$plan" "$manifest" <<'PY'
import hashlib
from pathlib import Path
import sys

plan = Path(sys.argv[1])
manifest = Path(sys.argv[2])
packages = {
    line.split("\t", 1)[0]
    for line in plan.read_text(encoding="utf-8").splitlines()
    if line
}
pack_listing = Path(".github/autobump-packs.tsv")
pack_packages = {
    fields[1]
    for line in pack_listing.read_text(encoding="utf-8").splitlines()
    if line and not line.startswith("#")
    for fields in [line.split()]
    if len(fields) == 2
}
if not packages.intersection(pack_packages):
    raise SystemExit(0)
rows = {}
lines = manifest.read_text(encoding="utf-8").splitlines()
if not lines or lines[0] != "# autobump-dependencies-v1":
    raise SystemExit("invalid dependency manifest header while refreshing hashes")
for line in lines[1:]:
    package, digest, dependencies = line.split("\t")
    rows[package] = (digest, dependencies)
for package in packages:
    if package in rows:
        template = Path("srcpkgs") / package / "template"
        digest, dependencies = rows[package]
        rows[package] = (hashlib.sha256(template.read_bytes()).hexdigest(), dependencies)
manifest.write_text(
    "# autobump-dependencies-v1\n"
    + "".join(f"{package}\t{rows[package][0]}\t{rows[package][1]}\n" for package in sorted(rows)),
    encoding="utf-8",
)
PY
	git add "$manifest"
	git commit --amend --no-edit
fi

# README is no longer generated here; package list lives on the website.

git push --force "https://x-access-token:${OCO_TOKEN}@github.com/${GH_REPO}.git" "HEAD:${BRANCH}"

echo "VERSION=$VERSION" >>"$GITHUB_ENV"
echo "BRANCH=$BRANCH" >>"$GITHUB_ENV"
echo "branch=$BRANCH" >>"$GITHUB_OUTPUT"
