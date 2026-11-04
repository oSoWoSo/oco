#!/usr/bin/env bash
set -euo pipefail

: "${XBPS_SRC:?XBPS_SRC is required for pack dependency resolution}"
# Pack members are checked for upstream updates. Direct build-dependent
# consumers of changed packages get revision bumps.
plan="$RUNNER_TEMP/autobump-plan.tsv"
args=(plan "$TEMPLATE" --output "$plan")
if [[ ${FORCE:-false} == true ]]; then args+=(--force); fi
.github/scripts/autobump-batch.py "${args[@]}"

if [[ ! -s $plan ]]; then
	echo "bumped=false" >>"$GITHUB_OUTPUT"
	echo "No newer version found in the selected pack or dependency component of $TEMPLATE"
	exit 0
fi

echo "bumped=true" >>"$GITHUB_OUTPUT"
echo "packages=$(cut -f1 "$plan" | paste -sd' ' -)" >>"$GITHUB_OUTPUT"
echo "count=$(cut -f1 "$plan" | wc -l)" >>"$GITHUB_OUTPUT"

# The branch is named after the target and the version it moves to.
# A target that only gets a revision bump has no new version, so
# the first version of the batch names the branch instead.
version=$(awk -F '\t' -v pkg="$TEMPLATE" '$1 == pkg { print $2; exit }' "$plan")
if [[ -z $version ]]; then
	version=$(awk -F '\t' '$3 == "version" { print $2; exit }' "$plan")
fi
[[ -n $version ]] || version=revbump
echo "version=$version" >>"$GITHUB_OUTPUT"
