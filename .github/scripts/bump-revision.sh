#!/usr/bin/env bash
# vim: set et sw=4 ts=4 filetype=sh :
#
# Raise the revision of a template without touching its version.
#
# Usage: bump-revision.sh <pkgname> [repo-root]
#
# A revision bump is what a package needs when one of its dependencies
# changed: the binaries have to be rebuilt against the new dependency even
# though the upstream version stayed the same.

set -euo pipefail

RC_ERROR=2

pkg=${1:?usage: bump-revision.sh <pkgname> [repo-root]}
root=${2:-$(git rev-parse --show-toplevel)}

cd "$root"

msg() {
	printf '%s\n' "$*" >&2
}

fail() {
	printf '::error::%s\n' "$*" >&2
	exit "$RC_ERROR"
}

tpl="srcpkgs/$pkg/template"
[ -f "$tpl" ] || fail "template not found: $tpl"
if [ -L "srcpkgs/$pkg" ]; then
	fail "srcpkgs/$pkg is a symlink, refusing to bump it"
fi

revision=$(sed -n 's/^revision=//p' "$tpl" | head -1 |
	sed -E 's/[[:space:]]*#.*$//' | tr -d '"' | tr -d "'" | tr -d '[:space:]')
case "$revision" in
'' | *[!0-9]*)
	fail "$pkg has no literal revision assignment"
	;;
esac

# The revision of a template that is only built as a subpackage of another
# one lives in the same file; a template that is symlinked to another one
# shares its revision and must not be bumped twice.
next=$((revision + 1))
sed -i -E "s/^revision=[0-9]+(.*)$/revision=${next}\1/" "$tpl"

printf '%s %s\n' "$pkg" "$next"
