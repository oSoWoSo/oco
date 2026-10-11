#!/usr/bin/env bash
# vim: set et sw=4 ts=4 filetype=sh :
#
# Bump a template to <newversion> and refresh its checksums.
#
# Usage: bump-template.sh <pkgname> <newversion>
#
# This is the xgensum subset the autobump whitelist needs: the templates in
# src/autobump-pkgs carry plain sha256 digests (no checksum_type), so the
# digests are computed with sha256sum instead of pulling in xgensum -- which
# would want a bootstrapped $XBPS_DISTDIR masterdir for a checksum we can get
# from the distfile itself.
#
# The distfiles are expanded by sourcing the template, because some of them
# derive URLs from variables (librewolf-bin's ${_distver}) and because the
# "url>name" rename syntax needs the same treatment xgensum applies.

set -euo pipefail

RC_ERROR=2

pkg=${1:?usage: bump-template.sh <pkgname> <newversion>}
new=${2:?usage: bump-template.sh <pkgname> <newversion>}
root=$(git rev-parse --show-toplevel)

cd "$root"

msg() {
	printf '%s\n' "$*" >&2
}

fail() {
	printf '::error::%s\n' "$*" >&2
	exit "$RC_ERROR"
}

case $new in
*[!0-9.]*)
	fail "refusing to bump $pkg to a non-version string: $new"
	;;
esac
case $new in
*.*) ;;
*) fail "refusing to bump $pkg to a non-version string: $new" ;;
esac

tpl="srcpkgs/$pkg/template"
[ -f "$tpl" ] || fail "template not found: $tpl"
if [ -L "srcpkgs/$pkg" ]; then
	fail "srcpkgs/$pkg is a symlink, refusing to bump it"
fi

if grep -q '^checksum_type=' "$tpl"; then
	fail "$pkg uses checksum_type=$(sed -n 's/^checksum_type=//p' "$tpl"); xgensum is required"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ -n "${GITHUB_TOKEN:-}" ]; then
	mkdir -m 700 "$tmp/curlhome"
	{
		for host in github.com api.github.com codeload.github.com \
			objects.githubusercontent.com raw.githubusercontent.com; do
			printf 'machine %s login x-access-token password %s\n' \
				"$host" "$GITHUB_TOKEN"
		done
	} >"$tmp/curlhome/_netrc"
	chmod 600 "$tmp/curlhome/_netrc"
	printf 'netrc-file = "%s"\n' "$tmp/curlhome/_netrc" >"$tmp/curlhome/.curlrc"
	export CURL_HOME="$tmp/curlhome"
fi

# Expand $distfiles with the template's own variable definitions. The template
# is sourced with do_* and pkg_* functions neutered: the values we want are
# plain assignments, but running arbitrary install hooks would be rude.
old=$(bash -c '. "$1"; printf %s "$version"' _ "./$tpl") ||
	fail "could not evaluate $tpl"

[ -n "$old" ] || fail "could not read version from $tpl"

if [ "$old" = "$new" ]; then
	msg "$pkg is already at $new"
	exit 0
fi

printf '::notice::%s: %s -> %s\n' "$pkg" "$old" "$new"

# -------------------------------------------------------------------------
# distfile expansion + checksums
#
# Everything below runs against the *new* version without touching the file
# yet: the template is only rewritten once every distfile has been fetched and
# hashed, so a failed download cannot leave a half-bumped template behind.
# Distfile expansion needs the template's own variable definitions (${version},
# librewolf-bin's derived ${_distver}, ...) and its unquoting conventions, which
# is exactly what xgensum does by sourcing the template. Run it in a subshell
# with nounset off: templates legitimately reference build-time variables.
# Expand the distfiles from a *pre-bumped copy* of the template: sourcing the
# real file would re-apply its own version= assignment and quietly download the
# old release instead, and the derived variables (librewolf-bin's ${_distver})
# are computed at source time so they follow the new version for free.
cp "$tpl" "$tmp/template.new"
python3 - "$tmp/template.new" "$old" "$new" <<'PY'
import re, sys

path, old, new = sys.argv[1:4]
src = open(path).read()
src, n = re.subn(r'^version=.*$', f'version={new}', src, count=1, flags=re.MULTILINE)
if n != 1:
    sys.exit(f'could not rewrite version= in {path}')
src, n = re.subn(r'^revision=.*$', 'revision=1', src, count=1, flags=re.MULTILINE)
if n != 1:
    sys.exit(f'could not rewrite revision= in {path}')

# A ">name" rename target sometimes hardcodes the old version (brow6el ships
# brow6el-v0.3.5.tar.gz), so keep the rename in sync with the bump.
src = re.sub(r'^distfiles=.*(?:\n .*)*$',
             lambda m: m.group(0).replace(old, new),
             src, count=1, flags=re.MULTILINE)
open(path, 'w').write(src)
PY

mapfile -t distfiles < <(
	set +u
	# shellcheck source=/dev/null
	. "$tmp/template.new"
	# shellcheck disable=SC2086
	printf '%s\n' $distfiles
)
[ "${#distfiles[@]}" -gt 0 ] || fail "$pkg has no distfiles"

sums=()
for url in "${distfiles[@]}"; do
	# "url>localname" renames; the checksum is of the downloaded bytes either
	# way, so fetch the URL and hash the result.
	fetch=${url%%>*}
	name=${url##*>}

	if [ "$name" = "$fetch" ]; then
		name=${fetch##*/}
		name=${name%%\?*}
	fi

	mkdir -p "$tmp/dl"
	out="$tmp/dl/$name"
	msg "fetching $fetch"
	curl --fail --location --retry 3 --retry-delay 2 --max-time 900 \
		--output "$out" "$fetch" || fail "download failed: $fetch"

	# An HTML error page served with a 200 is the classic false positive here.
	[ "$(wc -c <"$out")" -gt 1024 ] || fail "suspiciously small distfile: $fetch"
	if head -c 512 "$out" | grep -qiE '^<!doctype html|^<html'; then
		fail "distfile looks like HTML, not an archive: $fetch"
	fi

	sums+=("$(sha256sum "$out" | cut -d' ' -f1)")
done

# Rewrite the checksum block. The templates use either a bare value or a quoted
# multi-line block; either way the digests are one per line in distfile order,
# with continuation lines indented by a single space (xbps's own layout).
quoted=false
grep -q '^checksum="' "$tpl" && quoted=true

{
	if [ "$quoted" = true ]; then
		printf 'checksum="%s' "${sums[0]}"
		for sum in "${sums[@]:1}"; do
			printf '\n %s' "$sum"
		done
		printf '"\n'
	else
		for sum in "${sums[@]}"; do
			printf 'checksum=%s\n' "$sum"
		done
	fi
} >"$tmp/checksum"

python3 - "$tmp/template.new" "$tmp/checksum" <<'PY'
import re, sys

tpl, block_path = sys.argv[1:3]
block = open(block_path).read().rstrip('\n')
src = open(tpl).read()
src, n = re.subn(r'^checksum=.*(?:\n .*)*$', block, src, count=1, flags=re.MULTILINE)
if n != 1:
    sys.exit(f'could not rewrite the checksum block of {tpl}')
open(tpl, 'w').write(src)
PY

mv "$tmp/template.new" "$tpl"

printf '%s %s\n' "$pkg" "$new"
