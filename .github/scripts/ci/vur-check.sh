#!/usr/bin/env bash
# Copy an OCO template (plus the shlibs entries that concern it) onto a
# fresh OCO/<template> branch of oSoWoSo/VUR and force-push it there.
# VUR's check-anywhere workflow runs on any push touching srcpkgs/**, so
# the push itself triggers the official void-packages checks against the
# OCO template.
#
# Required env: TEMPLATE, VUR_TOKEN
set -euo pipefail

VUR_REPO="${VUR_REPO:-oSoWoSo/VUR}"
# Overridable for tests; defaults to the live repository.
VUR_GIT_URL="${VUR_GIT_URL:-https://x-access-token:${VUR_TOKEN}@github.com/${VUR_REPO}.git}"

[ -n "${TEMPLATE:-}" ] || { echo "::error::TEMPLATE is required"; exit 1; }
[ -n "${VUR_TOKEN:-}" ] || { echo "::error::VUR_TOKEN is required"; exit 1; }
case "$TEMPLATE" in
        ''|-*|*/*|*--*|*..*|*' '*|*$'\\'*|*$'\t'*) echo "::error::invalid template name: $TEMPLATE"; exit 1 ;;
esac

SRC="${GITHUB_WORKSPACE}/srcpkgs/${TEMPLATE}"
# Resolve symlinked srcpkgs entries (CRC-* -> Community-Repositories-Collection).
if [ -L "$SRC" ]; then
        SRC="$(readlink -f "$SRC")"
fi
[ -d "$SRC" ] || { echo "::error::template not found: srcpkgs/${TEMPLATE}"; exit 1; }

PKGNAME="$(sed -n 's/^pkgname=//p' "$SRC/template" | head -n1 | tr -d '"' | tr -d ' ')"
PKGNAME="${PKGNAME:-$TEMPLATE}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --quiet --depth 1 --branch VUR \
        "$VUR_GIT_URL" \
        "$WORK/vur"
cd "$WORK/vur"

git config user.name "oSoWoSo-bot"
git config user.email "mail@osowoso.org"

# Rebase the test branch on the latest VUR (synced from void-packages master).
git checkout --quiet -B "OCO/${TEMPLATE}" origin/VUR

# Overlay the OCO template directory.
rm -rf "srcpkgs/${TEMPLATE}"
cp -a "$SRC" "srcpkgs/${TEMPLATE}"

# Apply the OCO shlibs changes that concern this package.
append_shlibs() {
        local line pkgver
        [ -f "$1" ] || return 0
        while IFS= read -r line; do
                [ -n "$line" ] || continue
                pkgver="${line##* }"
                case "$pkgver" in
                        "$PKGNAME-"*|"$TEMPLATE-"*) ;;
                        *) continue ;;
                esac
                grep -qxF "$line" common/shlibs || echo "$line" >> common/shlibs
        done <"$1"
}
remove_shlibs() {
        local line pkgver
        [ -f "$1" ] || return 0
        while IFS= read -r line; do
                [ -n "$line" ] || continue
                pkgver="${line##* }"
                case "$pkgver" in
                        "$PKGNAME-"*|"$TEMPLATE-"*) ;;
                        *) continue ;;
                esac
                if grep -qxF "$line" common/shlibs; then
                        grep -vxF "$line" common/shlibs > common/shlibs.tmp || true
                        mv -f common/shlibs.tmp common/shlibs
                fi
        done <"$1"
}
append_shlibs "${GITHUB_WORKSPACE}/shlibs_append"
remove_shlibs "${GITHUB_WORKSPACE}/shlibs_remove"

git add "srcpkgs/${TEMPLATE}" common/shlibs
if git diff --cached --quiet; then
        echo "::error::nothing to test: srcpkgs/${TEMPLATE} already matches void-packages"
        exit 1
fi

VERSION="$(sed -n 's/^version=//p' "srcpkgs/${TEMPLATE}/template" | head -n1 | tr -d '"' | tr -d ' ')"
git commit --quiet -m "${PKGNAME} ${VERSION} (from OCO)"
git push --quiet --force origin "HEAD:OCO/${TEMPLATE}"

echo "::notice::pushed https://github.com/${VUR_REPO}/tree/OCO/${TEMPLATE}"
echo "::notice::check-anywhere: https://github.com/${VUR_REPO}/actions/workflows/check-anywhere.yml"