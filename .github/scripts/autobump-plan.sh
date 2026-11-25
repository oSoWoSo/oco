#!/usr/bin/env bash
set -euo pipefail

: "${XBPS_SRC:?XBPS_SRC is required for pack dependency resolution}"
if [[ $(python3 tools/autobump/autobump_packs.py "$TEMPLATE") != "${PACK:-}" ]]; then
	echo "::error::pack configuration changed while the bump was queued; retry the request"
	exit 1
fi
# Pack members are checked for upstream updates; direct consumers are
# revision-bumped only when the target belongs to a configured pack.
plan="$RUNNER_TEMP/autobump-plan.tsv"
args=(plan "$TEMPLATE" --output "$plan")
if [[ ${FORCE:-false} == true ]]; then args+=(--force); fi
tools/autobump/autobump-batch.py "${args[@]}"

if [[ ! -s $plan ]]; then
	echo "bumped=false" >>"$GITHUB_OUTPUT"
	echo "No newer version found for the selected autobump target/pack: $TEMPLATE"
	exit 0
fi

echo "bumped=true" >>"$GITHUB_OUTPUT"
echo "packages=$(cut -f1 "$plan" | paste -sd' ' -)" >>"$GITHUB_OUTPUT"
echo "count=$(cut -f1 "$plan" | wc -l)" >>"$GITHUB_OUTPUT"

# Single-package PRs still carry the upstream version in their title.
version=$(awk -F '\t' -v pkg="$TEMPLATE" '$1 == pkg { print $2; exit }' "$plan")
if [[ -z $version ]]; then
	version=$(awk -F '\t' '$3 == "version" { print $2; exit }' "$plan")
fi
[[ -n $version ]] || version=revbump
echo "version=$version" >>"$GITHUB_OUTPUT"
