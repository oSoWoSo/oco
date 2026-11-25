#!/usr/bin/env bash
set -euo pipefail

if [[ ${RETITLE:-false} == true ]]; then
	gh api "repos/${GH_REPO}/pulls/${EXISTING_PR}" --method PATCH -f title="$PACK" >/dev/null
	echo "number=$EXISTING_PR" >>"$GITHUB_OUTPUT"
	exit 0
fi

plan="$RUNNER_TEMP/autobump-plan.tsv"

printf '### Packages\n\n' >"$RUNNER_TEMP/pr-body.md"
printf '| package | change | version |\n|:-------|:-------|:-------|\n' \
	>>"$RUNNER_TEMP/pr-body.md"
while IFS=$'\t' read -r package version kind _order; do
	[[ -n $package ]] || continue
	template_url="https://github.com/${GH_REPO}/blob/${BRANCH}/srcpkgs/${package}/template"
	if [[ $kind == version ]]; then
		printf '| [`%s`](%s) | version | %s |\n' \
			"$package" "$template_url" "$version" >>"$RUNNER_TEMP/pr-body.md"
	else
		printf '| [`%s`](%s) | revision | unchanged |\n' \
			"$package" "$template_url" >>"$RUNNER_TEMP/pr-body.md"
	fi
done <"$plan"

printf '\n### Planned XBPS dependency order (pre-build)\n\n' >>"$RUNNER_TEMP/pr-body.md"
while IFS='|' read -r package _version _kind order; do
	[[ -n $package ]] || continue
	printf '%s. `%s`\n' "$((order + 1))" "$package" >>"$RUNNER_TEMP/pr-body.md"
done < <(tr '\t' '|' <"$plan")
printf '\nResolved with `xbps-src show-build-deps` before building; build-time discovery can add more dependencies.\n' \
	>>"$RUNNER_TEMP/pr-body.md"

printf '\nThe revision-only bumps rebuild the packages that depend on a\n' \
	>>"$RUNNER_TEMP/pr-body.md"
printf 'changed package, so the repository stops serving binaries linked\n' \
	>>"$RUNNER_TEMP/pr-body.md"
printf 'against the old dependency.\n' >>"$RUNNER_TEMP/pr-body.md"

if [[ -n ${ISSUE_NUMBER:-} ]]; then
	if [[ -n ${PACK:-} ]]; then
		printf '\nTracks #%s\n' "$ISSUE_NUMBER" >>"$RUNNER_TEMP/pr-body.md"
	else
		printf '\nCloses #%s\n' "$ISSUE_NUMBER" >>"$RUNNER_TEMP/pr-body.md"
	fi
fi
printf '\n' >>"$RUNNER_TEMP/pr-body.md"
if [[ -s $RUNNER_TEMP/osv-report.md ]]; then
	cat "$RUNNER_TEMP/osv-report.md" >>"$RUNNER_TEMP/pr-body.md"
else
	printf '### OSV advisory check: error\n\n**ERROR:** Advisory report could not be generated; no clean result is implied.\n' \
		>>"$RUNNER_TEMP/pr-body.md"
fi

title="${PACK:-$TEMPLATE $VERSION}"
if [[ -n ${EXISTING_PR:-} ]]; then
	number=$(gh api "repos/${GH_REPO}/pulls/${EXISTING_PR}" \
		--method PATCH -f title="$title" -F body=@"$RUNNER_TEMP/pr-body.md" --jq '.number')
else
	number=$(gh api "repos/${GH_REPO}/pulls" \
		--method POST -f title="$title" -f head="$BRANCH" -f base="${BASE_REF:-OCO}" \
		-F body=@"$RUNNER_TEMP/pr-body.md" --jq '.number')
fi

echo "number=$number" >>"$GITHUB_OUTPUT"
echo "PR: #${number}"
