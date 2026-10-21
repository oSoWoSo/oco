#!/usr/bin/env bash
# vim: set et sw=4 ts=4 filetype=sh :
#
# Detect a newer upstream version for a template.
#
# Usage: detect-update.sh <pkgname> [repo-root]
#
# Prints "<pkgname> <old> <new>" when a newer version exists, prints nothing
# when the template is up to date and exits 2 on error. RC_FIND_NEW=0 means
# "found nothing new".

set -euo pipefail

RC_FIND_NEW=0
RC_ERROR=2

pkg=${1:?usage: detect-update.sh <pkgname> [repo-root]}
root=${2:-$(git rev-parse --show-toplevel)}
image=${VOID_IMAGE:-ghcr.io/osowoso/oco-builder-x86_64:latest}

cd "$root"

msg() {
	printf '%s\n' "$*" >&2
}

fail() {
	printf '::error::%s\n' "$*" >&2
	exit "$RC_ERROR"
}

if [ -n "${XBPS_SRC:-}" ]; then
	engine=$XBPS_SRC
elif [ -x ./xbps-src ]; then
	engine=./xbps-src
elif [ -x /void-packages/xbps-src ]; then
	engine=/void-packages/xbps-src
else
	command -v docker >/dev/null 2>&1 ||
		fail "xbps-src and docker are unavailable; install xbps-src or run this on a Void host"
	exec docker run --rm -i \
		--user 1000:1000 \
		--volume "$root:/repo" \
		--volume "$root/srcpkgs:/void-packages/srcpkgs:ro" \
		--workdir /repo \
		--env HOME=/tmp \
		--env XBPS_USE_BUILD_MTIME=1 \
		--env GH_TOKEN="${GH_TOKEN:-}" \
		"$image" \
		bash .github/scripts/detect-update.sh "$pkg" /repo
fi

# Symlinked template directories (the -devel aliases) are never bumped.
if [ -L "srcpkgs/$pkg" ]; then
	fail "srcpkgs/$pkg is a symlink, refusing to bump it"
fi

tpl="srcpkgs/$pkg/template"
[ -f "$tpl" ] || fail "template not found: $tpl"

export XBPS_USE_BUILD_MTIME=1

old=$(sed -n 's/^version=//p' "$tpl" | head -1 | tr -d '"')
[ -n "$old" ] || fail "could not read version from $tpl"

if [ -n "${GH_TOKEN:-}" ]; then
	_curlhome=$(mktemp -d)
	# Holds GH_TOKEN in cleartext; remove it however we leave.
	trap 'chmod -R u+rwX "$_curlhome" 2>/dev/null; rm -rf "$_curlhome"' EXIT
	chmod 700 "$_curlhome"
	{
		for _host in api.github.com github.com raw.githubusercontent.com; do
			printf 'machine %s login x-access-token password %s\n' \
				"$_host" "$GH_TOKEN"
		done
	} >"$_curlhome/_netrc"
	chmod 600 "$_curlhome/_netrc"
	printf 'netrc-file = "%s"\n' "$_curlhome/_netrc" >"$_curlhome/.curlrc"
	export CURL_HOME="$_curlhome"
fi

set +e
out=$("$engine" update-check "$pkg")
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
	msg "$out"
	fail "$pkg: update-check exited $rc"
fi

# Match xxautobump: take field 3 from update-check output and select the
# version-sort maximum.
new=$(printf '%s\n' "$out" |
	cut -d' ' -f3 |
	sort -V |
	tail -n1 |
	sed "s/${pkg}-//")
# Upstream build numbers such as librewolf's "158.0.1-1" are stored with a
# dot ("158.0.1.1") so the template's version-derived distver keeps working.
new=$(printf '%s' "$new" | sed -E 's/-([0-9]+)$/.\1/')
: "${new:="$old"}"

if [ "$new" = "$old" ]; then
	msg "$pkg is already at $old"
	exit "$RC_FIND_NEW"
fi

printf '%s %s %s\n' "$pkg" "$old" "$new"
