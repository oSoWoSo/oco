#!/usr/bin/env bash
set -euo pipefail

BRANCH="${BRANCH_PREFIX:-autobump}/${TEMPLATE}"
BASE_REF="${BASE_REF:-OCO}"
plan="$RUNNER_TEMP/autobump-plan.tsv"
source_root=$(git rev-parse --show-toplevel)
source_manifest="$source_root/config/autobump-dependencies.tsv"
[[ -s "$plan" ]] || { echo '::error::Missing or empty autobump plan'; exit 1; }

# Never replace the workflow's own checkout: the base may predate the layout
# migration, and subsequent workflow steps still need the dispatched tooling.
work=$(mktemp -d "$RUNNER_TEMP/autobump-branch.XXXXXX")
branch_tree="$work/tree"
cleanup() {
	git -C "$source_root" worktree remove --force "$branch_tree" >/dev/null 2>&1 || true
	rm -rf "$work"
}
trap cleanup EXIT

git fetch --no-tags --depth=1 origin "+refs/heads/${BASE_REF}:refs/remotes/origin/${BASE_REF}"
git worktree add --detach "$branch_tree" "refs/remotes/origin/${BASE_REF}"
git -C "$branch_tree" config user.name "oSoWoSo-bot"
git -C "$branch_tree" config user.email "mail@osowoso.org"

# During migration the dispatched tooling and target base can have different
# layouts. Read/write metadata in the base's layout; never add the refactor to
# an unrelated package PR. Fail rather than silently omitting pack validation.
if [[ -f "$branch_tree/config/autobump-packs.tsv" ]]; then
	pack_listing="config/autobump-packs.tsv"
	manifest="config/autobump-dependencies.tsv"
elif [[ -f "$branch_tree/.github/autobump-packs.tsv" ]]; then
	pack_listing=".github/autobump-packs.tsv"
	manifest=".github/autobump-dependencies.tsv"
else
	echo "::error::${BASE_REF} has no autobump pack configuration"
	exit 1
fi

# Commit only the planned package changes on top of the freshly fetched base.
while IFS=$'\t' read -r package version kind _order; do
	[[ -n $package ]] || continue
	tpl="srcpkgs/$package/template"
	mkdir -p "$branch_tree/srcpkgs/$package"
	cp "$source_root/$tpl" "$branch_tree/$tpl"
	git -C "$branch_tree" add -f -- "$tpl"
	if git -C "$branch_tree" diff --cached --quiet; then
		echo "::error::rebase onto ${BASE_REF} left ${tpl} unchanged; nothing to bump"
		exit 1
	fi
	if [[ $kind == version ]]; then
		git -C "$branch_tree" commit -m "$package $version"
	else
		git -C "$branch_tree" commit -m "$package: raise revision for updated dependencies"
	fi
done <"$plan"
if [[ -f $source_manifest ]]; then
	mkdir -p "$branch_tree/$(dirname "$manifest")"
	cp "$source_manifest" "$branch_tree/$manifest"
	(
	cd "$branch_tree"
	python3 - "$plan" "$manifest" "$pack_listing" <<'PY'
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
pack_listing = Path(sys.argv[3])
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
	)
	git -C "$branch_tree" add -f -- "$manifest"
	git -C "$branch_tree" commit --amend --no-edit
fi

# Only this isolated package tree is pushed. The original checkout, templates,
# helper files, and metadata remain available to the rest of the workflow.
git -C "$branch_tree" push --force "https://x-access-token:${OCO_TOKEN}@github.com/${GH_REPO}.git" "HEAD:refs/heads/${BRANCH}"

echo "VERSION=$VERSION" >>"$GITHUB_ENV"
echo "BRANCH=$BRANCH" >>"$GITHUB_ENV"
echo "branch=$BRANCH" >>"$GITHUB_OUTPUT"
