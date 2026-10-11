#!/bin/sh
# Test runner for ocoman helpers.
# Usage: tests/run.sh
# Exit status is the number of failed tests (0 on success).

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)

_TEST_TMP=$(mktemp -d)
trap 'rm -rf "$_TEST_TMP"' EXIT INT TERM
cd "$_TEST_TMP" || exit 99

_PASS=0
_FAIL=0
_CURRENT=''

_red()   { printf '\033[0;31m%s\033[0m' "$1"; }
_green() { printf '\033[0;32m%s\033[0m' "$1"; }

it() { _CURRENT="$1"; }

assert_eq() {
	_got="$1" _want="$2"
	if [ "$_got" = "$_want" ]; then
		_PASS=$((_PASS + 1))
		printf '  %s %s\n' "$(_green '✓')" "$_CURRENT"
	else
		_FAIL=$((_FAIL + 1))
		printf '  %s %s\n      got:  %s\n      want: %s\n' \
			"$(_red '✗')" "$_CURRENT" "$_got" "$_want"
	fi
}

assert_rc() {
	_got="$1" _want="$2"
	if [ "$_got" -eq "$_want" ]; then
		_PASS=$((_PASS + 1))
		printf '  %s %s\n' "$(_green '✓')" "$_CURRENT"
	else
		_FAIL=$((_FAIL + 1))
		printf '  %s %s (rc=%s, want=%s)\n' \
			"$(_red '✗')" "$_CURRENT" "$_got" "$_want"
	fi
}

. "$SCRIPT_DIR/src/pkg-helpers.sh"

# ocoman's _r() prints ANSI colours from RED/NC, which it only defines when
# NO_COLOR is unset. The awk extractor pulls _r() and fatal() but not that
# block, so seed the two variables _r() actually reads.
RED='' GREEN='' YELLOW='' BLUE='' NC=''

eval "$(awk '
	/^_r\(\)/             {p=1}
	/^fatal\(\)/          {p=1}
	/^pkg_name\(\)/        {p=1}
	/^fetch_remote_list\(\)/ {p=1}
	/^surf_cli_init\(\)/ {p=1}
	/^surf_cli\(\)/        {p=1}
	/^surf_diagnose\(\)/  {p=1}
	/^surf_retry_loop\(\)/{p=1}
	/^surf_retry\(\)/     {p=1}
	/^repodata_looks_valid\(\)/ {p=1}
	/^fetch_repodata\(\)/ {p=1}
	/^delete_remote\(\)/   {p=1}
	/^upload_file\(\)/   {p=1}
	/^prune_orphans\(\)/ {p=1}
	/^delete_orphan_files\(\)/ {p=1}
	/^read_template_fields/{p=1}
	/^feed_xml_escape/     {p=1}
	/^feed_urls_from_nvchecker/{p=1}
	/^feed_urls_from_homepage/{p=1}
	/^feed_opml_has/       {p=1}
	p {print}
	p && /^}$/             {p=0}
' "$SCRIPT_DIR/ocoman")"

# Mirrors ocoman's Surfer defaults; individual sections override them.
# Every helper above reads these, so they must exist before the first call.
export SURF_ATTEMPTS=4 SURF_BACKOFF=0
export SURF_DEADLINE=1500 SURF_CONNECT_TIMEOUT=20 SURF_MAX_TIME=300 SURF_BACKOFF_MAX=30
export SURFER_URL='https://repo.osowoso.org'

# surf_cli_init() reads _SURF_READY, which ocoman initialises at file scope.
# The awk extractor above only pulls function bodies, so that initialisation
# is missing here -- and 'set -u' turns reading it into a fatal "unbound
# variable". Sections clear it to force a fresh credential check.
_SURF_READY="${_SURF_READY:-}"

REPODATA_STRIP_PY="$SCRIPT_DIR/src/repodata-strip.py"

echo '== pkg_name =='
it 'plain name';            assert_eq "$(pkg_name 'foo-1.0_1.x86_64')"          'foo'
it '+ in name';             assert_eq "$(pkg_name 'quickshell+-1.0_1.x86_64')"  'quickshell+'
it 'digit in name';         assert_eq "$(pkg_name 'gtk+3-3.24.42_1.x86_64')"    'gtk+3'
it 'hyphenated name';       assert_eq "$(pkg_name 'python3-PyGithub-1.59_1.x86_64')" 'python3-PyGithub'
it 'musl arch suffix';      assert_eq "$(pkg_name 'foo-1.2_1.aarch64-musl')"    'foo'
it 'caller stripped .xbps'; assert_eq "$(pkg_name 'foo-1.0_1.x86_64')"          'foo'
it 'caller passed .xbps';   assert_eq "$(pkg_name 'foo-1.0_1.x86_64.xbps')"     'foo'

echo '== pkg_arch_ok =='

_mktpl() {
	mkdir -p srcpkgs/_t
	if [ -z "$1" ]; then
		: > srcpkgs/_t/template
	else
		printf 'archs="%s"\n' "$1" > srcpkgs/_t/template
	fi
}

_mktpl 'x86_64'
it 'archs=x86_64 vs x86_64';      pkg_arch_ok _t x86_64;       assert_rc $? 0
it 'archs=x86_64 vs aarch64';     pkg_arch_ok _t aarch64;      assert_rc $? 1

_mktpl 'x86_64 aarch64'
it 'multi-arch positive';         pkg_arch_ok _t aarch64;      assert_rc $? 0
it 'multi-arch negative';         pkg_arch_ok _t i686;         assert_rc $? 1

_mktpl '~i686'
it 'exclusion: passes other';     pkg_arch_ok _t x86_64;       assert_rc $? 0
it 'exclusion: blocks excluded';  pkg_arch_ok _t i686;         assert_rc $? 1

_mktpl '*'
it 'glob *: matches everything';  pkg_arch_ok _t aarch64-musl; assert_rc $? 0

_mktpl '*-musl'
it 'glob *-musl: positive';       pkg_arch_ok _t aarch64-musl; assert_rc $? 0
it 'glob *-musl: negative';       pkg_arch_ok _t x86_64;       assert_rc $? 1

_mktpl ''
it 'empty archs (allow all)';     pkg_arch_ok _t aarch64;      assert_rc $? 0

it 'missing template (allow all)'
rm -rf srcpkgs/_t
pkg_arch_ok _t aarch64; assert_rc $? 0

echo '== read_template_fields =='

_mkfull_tpl() {
	mkdir -p srcpkgs/_t
	cat > srcpkgs/_t/template <<'EOF'
# Template file for 'foo'
pkgname=foo
version=1.2.3
revision=1
short_desc="A short description with spaces and = sign"
maintainer="Jane Doe <jane@example.com>"
homepage="https://example.com/foo?bar=baz"
archs="x86_64 ~i686"
license="MIT"
EOF
}

_mkfull_tpl
read_template_fields srcpkgs/_t/template

it 'version';     assert_eq "$_tpl_version"     '1.2.3'
it 'short_desc';  assert_eq "$_tpl_short_desc"  'A short description with spaces and = sign'
it 'maintainer';  assert_eq "$_tpl_maintainer"  'Jane Doe'
it 'homepage';    assert_eq "$_tpl_homepage"    'https://example.com/foo?bar=baz'
it 'archs';       assert_eq "$_tpl_archs"       'x86_64 ~i686'

cat > srcpkgs/_t/template <<'EOF'
version=1.0
version=2.0
EOF
read_template_fields srcpkgs/_t/template
it 'first version wins'; assert_eq "$_tpl_version" '1.0'

: > srcpkgs/_t/template
read_template_fields srcpkgs/_t/template
it 'empty template -> empty version'; assert_eq "$_tpl_version" ''
it 'empty template -> empty archs';   assert_eq "$_tpl_archs"   ''

echo '== feed (feed.opml) helpers =='

NVCONF="$PWD/nvchecker.toml"
FEED_OPML="$PWD/feed.opml"

cat > "$NVCONF" <<'EOF'
[__config__]
oldver = "old_ver.json"

[aquamarine]
source = "github"
use_max_tag = true
github = "hyprwm/aquamarine"
prefix = "v"

["quickshell+"]
source = "gitea"
use_max_tag = true
gitea = "quickshell/quickshell"
host = "git.outfoxxed.me"
prefix = "v"

[hyprlock]
source = "github"
use_max_tag = true
github = "hyprwm/${pkgname}"
prefix = "v"

[sdkmanager]
source = "gitlab"
use_max_tag = true
gitlab = "fdroid/sdkmanager"
host = "gitlab.com"

[python3-textual]
source = "pypi"
pypi = "textual"
EOF

feed_urls_from_nvchecker aquamarine
it 'nvchecker github rc';   assert_rc $? 0
it 'nvchecker github xml';  assert_eq "$_feed_xml_url"  'https://github.com/hyprwm/aquamarine/tags.atom'
it 'nvchecker github html'; assert_eq "$_feed_html_url" 'https://github.com/hyprwm/aquamarine/releases'

feed_urls_from_nvchecker 'quickshell+'
it 'nvchecker gitea xml';  assert_eq "$_feed_xml_url"  'https://git.outfoxxed.me/quickshell/quickshell/tags.rss'
it 'nvchecker gitea html'; assert_eq "$_feed_html_url" 'https://git.outfoxxed.me/quickshell/quickshell/tags'

feed_urls_from_nvchecker hyprlock
it 'nvchecker pkgname subst'; assert_eq "$_feed_xml_url" 'https://github.com/hyprwm/hyprlock/tags.atom'

feed_urls_from_nvchecker sdkmanager
it 'nvchecker gitlab xml';  assert_eq "$_feed_xml_url"  'https://gitlab.com/fdroid/sdkmanager/-/tags?format=atom'
it 'nvchecker gitlab html'; assert_eq "$_feed_html_url" 'https://gitlab.com/fdroid/sdkmanager/-/tags'

it 'nvchecker pypi rc'
feed_urls_from_nvchecker 'python3-textual'
assert_rc $? 1

it 'nvchecker missing rc'
feed_urls_from_nvchecker no-such-pkg
assert_rc $? 1

rm -f "$NVCONF"
it 'nvchecker missing file rc'
feed_urls_from_nvchecker aquamarine
assert_rc $? 1

feed_urls_from_homepage 'https://github.com/zen-browser/desktop'
it 'homepage github xml';  assert_eq "$_feed_xml_url"  'https://github.com/zen-browser/desktop/tags.atom'
it 'homepage github html'; assert_eq "$_feed_html_url" 'https://github.com/zen-browser/desktop/releases'

feed_urls_from_homepage 'https://codeberg.org/oSoWoSo/gum'
it 'homepage codeberg xml'; assert_eq "$_feed_xml_url" 'https://codeberg.org/oSoWoSo/gum/tags.rss'

feed_urls_from_homepage 'https://gitlab.com/fdroid/sdkmanager'
it 'homepage gitlab xml'; assert_eq "$_feed_xml_url" 'https://gitlab.com/fdroid/sdkmanager/-/tags?format=atom'

it 'homepage website rc'
feed_urls_from_homepage 'https://hyprland.org/'
assert_rc $? 1

cat > "$FEED_OPML" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0">
    <body>
        <outline text="All">
            <outline title="Repology" text="Repology" xmlUrl="https://repology.org/a.atom" htmlUrl="https://repology.org/" type="rss"></outline>
        </outline>
        <outline text="package-update">
            <outline title="drako" text="drako" xmlUrl="https://github.com/lucky7xz/drako/tags.atom" htmlUrl="https://github.com/lucky7xz/drako/releases" type="rss"></outline>
            <outline title="quickshell+" text="quickshell+" xmlUrl="https://git.outfoxxed.me/quickshell/quickshell/tags.atom" htmlUrl="https://git.outfoxxed.me/quickshell/quickshell/tags" type="rss"></outline>
        </outline>
    </body>
</opml>
EOF

feed_opml_has drako;       assert_rc $? 0
feed_opml_has 'quickshell+'; assert_rc $? 0
feed_opml_has gofer;       assert_rc $? 1
feed_opml_has _t;          assert_rc $? 1

rm -f "$FEED_OPML"
feed_opml_has drako;       assert_rc $? 1

it 'xml escape'; assert_eq "$(feed_xml_escape 'a&b<c>d"e')" 'a&amp;b&lt;c&gt;d&quot;e'

# Fake transport binaries live in one directory; the surfer CLI section
# below reuses it, so the directory outlives every section that needs it.
_FAKE_BIN=$(mktemp -d)
PATH_BACKUP="$PATH"

echo '== prune_orphans / delete_orphan_files =='

# Two separate responsibilities:
#   prune_orphans      DETECTS packages with no template in srcpkgs/ and writes
#                      their names out; it never deletes anything.
#   delete_orphan_files removes the binaries for those names.
# Keeping detection apart from deletion is what lets the index get stripped
# first and the litter cleaned afterwards, in do_upload's order.
rm -rf srcpkgs
mkdir -p srcpkgs/keepme srcpkgs/alsokeep
: > srcpkgs/keepme/template
: > srcpkgs/alsokeep/template

eval "$(awk '
	/^prune_orphans\(\)/ {p=1}
	/^delete_orphan_files\(\)/ {p=1}
	p {print}
	p && /^}$/           {p=0}
' "$SCRIPT_DIR/ocoman")"

# Record the paths handed to delete_remote instead of touching a transport, so
# the assertion is about the LIST ocoman builds, not about a particular client.
_DELETED=$(mktemp)
delete_remote() { printf '%s\n' "$1" >> "$_DELETED"; }
_SCRIPT_DIR_BACKUP="$SCRIPT_DIR"
SCRIPT_DIR="$PWD"
SRCPKGS=srcpkgs ARCH=x86_64

_orphans=$(mktemp)
_empty_orphans=$(mktemp)
prune_orphans "$(printf '%s\n' \
	'keepme-1.0_1.x86_64.xbps' \
	'alsokeep-2.0_1.x86_64.xbps' \
	'gone-1.0_1.x86_64.xbps' \
	'dropped-3.0_1.x86_64.xbps')" "$_orphans" >/dev/null

it 'orphans file lists only removed packages'
assert_eq "$(sort "$_orphans" | tr '\n' ',')" 'dropped,gone,'

it 'prune_orphans only detects; it issues no delete'
assert_eq "$(wc -c < "$_DELETED" | tr -d ' ')" '0'

it 'delete_orphan_files removes the binary and its signature'
: > "$_DELETED"
delete_orphan_files "$_orphans" "$(printf '%s\n' 'gone-1.0_1.x86_64.xbps')" >/dev/null 2>&1
it 'deletes the .xbps'
assert_eq "$(grep -c '^/x86_64/gone-1\.0_1\.x86_64\.xbps$' "$_DELETED")" '1'
it 'deletes the .sig2 alongside it'
assert_eq "$(grep -c '^/x86_64/gone-1\.0_1\.x86_64\.xbps\.sig2$' "$_DELETED")" '1'

it 'delete_orphan_files leaves packages that still have a template'
assert_eq "$(grep -c 'keepme' "$_DELETED"; true)" '0'
assert_eq "$(grep -c 'alsokeep' "$_DELETED"; true)" '0'

it 'delete_orphan_files ignores an unlisted orphan'
: > "$_DELETED"
delete_orphan_files "$(printf '%s\n' 'gone\n')" "$(printf '%s\n' \
	'gone-1.0_1.x86_64.xbps' \
	'keepme-1.0_1.x86_64.xbps')" >/dev/null 2>&1
assert_eq "$(grep -c 'keepme' "$_DELETED"; true)" '0'

it 'delete_orphan_files is a no-op with an empty orphan list'
: > "$_DELETED"
: > "$_empty_orphans"
delete_orphan_files "$_empty_orphans" "$(printf '%s\n' 'gone-1.0_1.x86_64.xbps')" >/dev/null 2>&1
assert_eq "$(wc -c < "$_DELETED" | tr -d ' ')" '0'

rm -f "$_orphans" "$_empty_orphans" "$_DELETED"
rm -rf srcpkgs
SCRIPT_DIR="$_SCRIPT_DIR_BACKUP"

# Drop the stub: the real delete_remote (surfer del) is what the CLI section
# below exercises through the fake surfer, so it has to be back in place.
eval "$(awk '
	/^delete_remote\(\)/ {p=1}
	p {print}
	p && /^}$/           {p=0}
' "$SCRIPT_DIR/ocoman")"


echo '== do_upload: arch isolation (P0) =='

# xbps-src leaves every architecture's .xbps in one binpkgs/ directory. An
# unqualified glob therefore republishes foreign arches into this arch's
# directory -- which happened on 2026-09-27 (an aarch64-musl job uploaded
# lunasvg-3.5.0_3.x86_64-musl.xbps). Assert on the source text: the glob is
# the thing that must stay pinned to ${ARCH}.
_DOUPLOAD=$(sed -n '/^do_upload()/,/^}$/p' "$SCRIPT_DIR/ocoman")

it 'new packages are copied with an architecture filter'
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -c 'cp "${_builddir}"/\*\."${ARCH}"\.xbps ')" '1'

it 'xbps-rindex only indexes this architecture'
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -c 'xbps-rindex -a \./\*\."${ARCH}"\.xbps')" '1'

it 'both upload loops filter on the architecture'
# Packages and signatures go up in one pass, so the globs share a line.
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -c 'for _file in \./\*\."${ARCH}"\.xbps \./\*\."${ARCH}"\.xbps\.sig2')" '1'
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -c 'for _file in \./\*-repodata')" '1'

it 'no unfiltered package glob survives anywhere in do_upload'
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -cE '\./\*\.xbps|"\$\{_builddir\}"/\*\.xbps')" '0'

it 'SURF_PURGE_PACKAGES merges explicit names into the strip list'
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -c 'if \[ -n "\$SURF_PURGE_PACKAGES" \]')" '1'
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -c "grep -qx \"\\\$_p\" \"\\\${PWD}/orphans.txt\"")" '1'

it 'packages are uploaded before the index'
_pkg_line=$(printf '%s' "$_DOUPLOAD" | grep -n '==> Uploading packages' | cut -d: -f1)
_idx_line=$(printf '%s' "$_DOUPLOAD" | grep -n '==> Uploading repository index' | cut -d: -f1)
if [ -n "$_pkg_line" ] && [ -n "$_idx_line" ] && [ "$_pkg_line" -lt "$_idx_line" ]; then
	assert_eq 'ok' 'ok'
else
	assert_eq "packages at ${_pkg_line}, index at ${_idx_line}" 'ok'
fi

it 'old package versions are deleted only after index upload'
_idx_upload_line=$(printf '%s' "$_DOUPLOAD" | grep -n 'upload_file "$_file" "${_arch_dir}"' | tail -n1 | cut -d: -f1)
_old_delete_line=$(printf '%s' "$_DOUPLOAD" | grep -n 'Cleaning old package versions from remote' | cut -d: -f1)
if [ -n "$_idx_upload_line" ] && [ -n "$_old_delete_line" ] && [ "$_old_delete_line" -gt "$_idx_upload_line" ]; then
	assert_eq 'ok' 'ok'
else
	assert_eq "index upload at ${_idx_upload_line}, old-version GC at ${_old_delete_line}" 'ok'
fi

it 'a failed package upload aborts before the index is published'
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -c 'remote repodata left untouched')" '1'

it 'xbps-rindex add/sign and signing-key write failures are fatal'
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -c 'xbps-rindex failed to add packages')" '1'
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -c 'xbps-rindex failed to sign repository')" '1'
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -c 'failed to write signing key')" '1'

it 'a failed repodata-strip aborts the upload instead of republishing a stale index'
# The old code swallowed a strip failure with a warning and kept uploading the
# still-stale repodata; that is exactly how tomlplusplus/tomlplusplus-devel
# stayed advertised (with the .xbps gone) and broke `xbps-src pkg hyprcursor`.
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -c 'fatal "==> repodata-strip failed')" '1'
assert_eq "$(printf '%s' "$_DOUPLOAD" | grep -c "|| echo '  Warning: repodata-strip failed")" '0'

echo '== init destination safety =='
eval "$(awk '
	/^init_destination_guard\(\)/ {p=1}
	p {print}
	p && /^}$/ {p=0}
' "$SCRIPT_DIR/ocoman")"

_init_test_dir=$(mktemp -d)
CLONE_DEST="$_init_test_dir/empty"
mkdir "$CLONE_DEST"
OCOMAN_INIT_FORCE=
it 'init permits an empty destination without force'
(init_destination_guard >/dev/null 2>&1); assert_rc $? 0

mkdir "$CLONE_DEST/valuable"
it 'init refuses to delete a non-empty destination by default'
(init_destination_guard >/dev/null 2>&1); assert_rc $? 1

OCOMAN_INIT_FORCE=1
it 'init permits a non-empty destination with explicit force'
(init_destination_guard >/dev/null 2>&1); assert_rc $? 0

OCOMAN_INIT_FORCE=
CLONE_DEST=/
it 'init refuses a dangerous root destination by default'
(init_destination_guard >/dev/null 2>&1); assert_rc $? 1
rm -rf "$_init_test_dir"

echo '== repodata-list.py =='

if command -v python3 >/dev/null 2>&1; then
	_wd=$(mktemp -d)
	(
		cd "$_wd" || exit 1
		python3 -c '
import plistlib
open("index.plist","wb").write(plistlib.dumps({
    "alpha": {"pkgver":"alpha-1_1"},
    "alpha-devel": {"pkgver":"alpha-devel-1_1"},
    "zeta": {"pkgver":"zeta-9_1"},
}, fmt=plistlib.FMT_XML))
'
		tar -cf x86_64-repodata index.plist
		python3 "$SCRIPT_DIR/src/repodata-list.py" x86_64-repodata | sort | tr '\n' ','
	) > "$_wd/out"
	it 'lists all package names'
	assert_eq "$(cat "$_wd/out")" 'alpha,alpha-devel,zeta,'

	(
		cd "$_wd" || exit 1
		python3 -c 'import plistlib; open("index.plist","wb").write(plistlib.dumps({}, fmt=plistlib.FMT_XML))'
		tar -cf empty-repodata index.plist
		python3 "$SCRIPT_DIR/src/repodata-list.py" empty-repodata
	) > "$_wd/out"; _rc=$?
	it 'empty index: rc 0';        assert_rc "$_rc" 0
	it 'empty index: no output';   assert_eq "$(cat "$_wd/out")" ''

	python3 "$SCRIPT_DIR/src/repodata-list.py" >/dev/null 2>&1; _rc=$?
	it 'missing arg: rc 2';        assert_rc "$_rc" 2

	echo bogus > "$_wd/garbage"
	python3 "$SCRIPT_DIR/src/repodata-list.py" "$_wd/garbage" >/dev/null 2>&1; _rc=$?
	it 'garbage input: rc 1';      assert_rc "$_rc" 1

	if command -v zstd >/dev/null 2>&1; then
		(
			cd "$_wd" || exit 1
			python3 -c '
import plistlib
open("index.plist","wb").write(plistlib.dumps({
    "zst-a": {"v":1}, "zst-b": {"v":2},
}, fmt=plistlib.FMT_XML))
'
			tar -cf zst.tar index.plist
			zstd -q -o zst-repodata zst.tar
			python3 "$SCRIPT_DIR/src/repodata-list.py" zst-repodata | sort | tr '\n' ','
		) > "$_wd/out"
		it 'zstd input: lists all entries'
		assert_eq "$(cat "$_wd/out")" 'zst-a,zst-b,'

		(
			cd "$_wd" || exit 1
			python3 "$SCRIPT_DIR/src/repodata-strip.py" zst-repodata zst-a >/dev/null
			head -c 4 zst-repodata | od -An -tx1 | tr -d ' \n'
		) > "$_wd/out"
		it 'zstd strip: output is still zstd'
		assert_eq "$(cat "$_wd/out")" '28b52ffd'

		(
			cd "$_wd" || exit 1
			python3 "$SCRIPT_DIR/src/repodata-list.py" zst-repodata | tr '\n' ','
		) > "$_wd/out"
		it 'zstd strip: surviving entry is correct'
		assert_eq "$(cat "$_wd/out")" 'zst-b,'
	else
		echo '  (skipped: zstd CLI not on PATH)'
	fi

	rm -rf "$_wd"
else
	echo '  (skipped: python3 not on PATH)'
fi

echo '== repodata-strip.py =='

if command -v python3 >/dev/null 2>&1; then
	_workdir=$(mktemp -d)
	(
		cd "$_workdir" || exit 1
		python3 -c '
import plistlib
with open("index.plist", "wb") as f:
    f.write(plistlib.dumps({
        "alpha": {"pkgver": "alpha-1_1"},
        "beta":  {"pkgver": "beta-2_1"},
        "gamma": {"pkgver": "gamma-3_1"},
    }, fmt=plistlib.FMT_XML))
'
		tar -cf x86_64-repodata index.plist
		python3 "$SCRIPT_DIR/src/repodata-strip.py" \
			x86_64-repodata beta nope >/dev/null
		tar -xOf x86_64-repodata index.plist | python3 -c '
import sys, plistlib
print(",".join(sorted(plistlib.loads(sys.stdin.buffer.read()).keys())))
'
	) > "$_workdir/out"
	it 'strips listed entry; leaves rest'
	assert_eq "$(cat "$_workdir/out")" 'alpha,gamma'
	rm -rf "$_workdir"
else
	echo '  (skipped: python3 not on PATH)'
fi

echo '== repo key plists =='

if command -v python3 >/dev/null 2>&1; then
	for _plist in "$SCRIPT_DIR/oco-repo-key.plist"; do
		_plist_have=$(python3 - "$_plist" <<'PYEOF'
import plistlib, base64, hashlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
pub = d['public-key']
if d.get('public-key-size') != 4096:
    raise SystemExit('bad public-key-size')
if d.get('signature-by') != 'oSoWoSo <mail@osowoso.org>':
    raise SystemExit('bad signature-by')
if d.get('signature-type') != 'rsa':
    raise SystemExit('bad signature-type')
if not pub.startswith(b'-----BEGIN PUBLIC KEY-----') or not pub.endswith(b'-----END PUBLIC KEY-----\n'):
    raise SystemExit('public-key is not PEM text')
# SSH-style RSA fingerprint; must stay df:ec:10:... so the CI key file
# name keeps matching the repo's index-meta.plist.
pem = pub.decode().strip()
der = base64.b64decode(''.join(pem.split('\n')[1:-1]))
i = 0
assert der[i] == 0x30; i += 1
l = der[i]; i += 1
if l & 0x80:
    nlen = l & 0x7f
    l = int.from_bytes(der[i:i+nlen], 'big'); i += nlen
assert der[i] == 0x30; i += 1
l = der[i]; i += 1
if l & 0x80:
    nlen = l & 0x7f
    l = int.from_bytes(der[i:i+nlen], 'big'); i += nlen
i += l
assert der[i] == 0x03; i += 1
l = der[i]; i += 1
if l & 0x80:
    nlen = l & 0x7f
    l = int.from_bytes(der[i:i+nlen], 'big'); i += nlen
i += 1
assert der[i] == 0x30; i += 1
l = der[i]; i += 1
if l & 0x80:
    nlen = l & 0x7f
    l = int.from_bytes(der[i:i+nlen], 'big'); i += nlen
assert der[i] == 0x02; i += 1
l = der[i]; i += 1
if l & 0x80:
    nlen = l & 0x7f
    l = int.from_bytes(der[i:i+nlen], 'big'); i += nlen
n = der[i:i+l]; i += l
assert der[i] == 0x02; i += 1
l = der[i]; i += 1
if l & 0x80:
    nlen = l & 0x7f
    l = int.from_bytes(der[i:i+nlen], 'big'); i += nlen
e = der[i:i+l]
def ssh_encode(b):
    b = (b'\x00' + b) if b[0] & 0x80 else b
    return len(b).to_bytes(4, 'big') + b
blob = b'\x00\x00\x00\x07ssh-rsa' + ssh_encode(e) + ssh_encode(n)
fp = ':'.join('%02x' % x for x in hashlib.md5(blob).digest())
if fp != 'df:ec:10:ef:5c:03:e9:e0:9e:86:77:08:c2:b5:a8:cb':
    raise SystemExit('fingerprint mismatch: ' + fp)
print('ok')
PYEOF
)
		it "parses and key fingerprint matches: ${_plist#"$SCRIPT_DIR"/}"
		assert_eq "$_plist_have" 'ok'
	done
else
	echo '  (skipped: python3 not on PATH)'
fi

echo '== gen-feed.py =='

if command -v python3 >/dev/null 2>&1; then
	_gf_wd=$(mktemp -d)
	mkdir -p "$_gf_wd/results/build-results-x86_64" \
		"$_gf_wd/results/build-results-aarch64" \
		"$_gf_wd/srcpkgs/tor"
	printf 'tor\t0.4.8.11\tok\nfailme\t1.0\tfail\n' > "$_gf_wd/results/build-results-x86_64/results.tsv"
	printf 'tor\t0.4.8.11\tok\n' > "$_gf_wd/results/build-results-aarch64/results.tsv"
	cat > "$_gf_wd/srcpkgs/tor/template" <<'EOF'
version=0.4.8.11
homepage=https://example.org/tor
short_desc="An overlay network"
EOF
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/feed.xml" "$_gf_wd/results" 42 2026-09-10 "$_gf_wd/srcpkgs" >/dev/null

	it 'first run: one item per ok pkg'
	assert_eq "$(grep -c '<item>' "$_gf_wd/feed.xml")" '1'
	it 'item title carries pkg+version'
	grep -q '<title>tor 0.4.8.11</title>' "$_gf_wd/feed.xml"; assert_rc $? 0
	it 'guid = pkg-version'
	grep -q 'guid isPermaLink="false">tor-0.4.8.11' "$_gf_wd/feed.xml"; assert_rc $? 0
	it 'ok arches listed, failed arch skipped'
	grep -q 'Archs: aarch64 x86_64' "$_gf_wd/feed.xml"; assert_rc $? 0
	it 'template homepage used as item link'
	grep -q '<link>https://example.org/tor</link>' "$_gf_wd/feed.xml"; assert_rc $? 0
	it 'codeberg is the only template link in description'
	grep -q 'codeberg.org/oSoWoSo/oco/src/branch/OCO/srcpkgs/tor/template">template</a>' "$_gf_wd/feed.xml"; assert_rc $? 0
	grep -vq 'github.com/oSoWoSo/Void_Community_Repository/blob/OCO/srcpkgs/tor/template' "$_gf_wd/feed.xml"; assert_rc $? 0
	it 'CI run link in description'
	grep -q 'actions/runs/42' "$_gf_wd/feed.xml"; assert_rc $? 0
	it 'output is valid XML'
	python3 -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$_gf_wd/feed.xml"; assert_rc $? 0

	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/feed.xml" "$_gf_wd/results" 99 2026-09-11 "$_gf_wd/srcpkgs" >/dev/null
	it 'same-version rebuild: no new item'
	assert_eq "$(grep -c '<item>' "$_gf_wd/feed.xml")" '1'
	it 'same-version rebuild: date updated'
	grep -q 'Fri, 11 Sep 2026' "$_gf_wd/feed.xml"; assert_rc $? 0
	it 'same-version rebuild: run link updated'
	grep -q 'actions/runs/99' "$_gf_wd/feed.xml"; assert_rc $? 0

	printf 'tor\t0.4.8.12\tok\n' > "$_gf_wd/results/build-results-x86_64/results.tsv"
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/feed.xml" "$_gf_wd/results" 100 2026-09-12 "$_gf_wd/srcpkgs" >/dev/null
	it 'version bump adds new item'
	assert_eq "$(grep -c '<item>' "$_gf_wd/feed.xml")" '2'
	it 'history retains previous version'
	grep -q 'tor-0.4.8.11' "$_gf_wd/feed.xml"; assert_rc $? 0
	it 'history adds new version item'
	grep -q 'tor-0.4.8.12' "$_gf_wd/feed.xml"; assert_rc $? 0

	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/feed.xml" "$_gf_wd/empty" 100 2026-09-12 "$_gf_wd/srcpkgs" 2>/dev/null >/dev/null
	it 'no results dir: item count unchanged'
	assert_eq "$(grep -c '<item>' "$_gf_wd/feed.xml")" '2'

	mkdir -p "$_gf_wd/cap/build-results-x86_64"
	_i=0
	while [ "$_i" -lt 1100 ]; do
		printf 'pkg%s\t%s.0\tok\n' "$_i" "$_i" >> "$_gf_wd/cap/build-results-x86_64/results.tsv"
		_i=$((_i + 1))
	done
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/cap.xml" "$_gf_wd/cap" 100 2026-09-12 "$_gf_wd/srcpkgs" >/dev/null
	it 'cap: feed limited to 1000 items'
	assert_eq "$(grep -c '<item>' "$_gf_wd/cap.xml")" '1000'

	_titles() {
		python3 -c '
import sys, xml.etree.ElementTree as ET
print(" ".join(i.findtext("title", "").split()[0]
               for i in ET.parse(sys.argv[1]).getroot().iter("item")))
' "$1"
	}

	mkdir -p "$_gf_wd/ts/a/build-results-x86_64" \
		"$_gf_wd/ts/b/build-results-x86_64" \
		"$_gf_wd/ts/c/build-results-x86_64"
	printf 'alpha\t1.0\tok\n' > "$_gf_wd/ts/a/build-results-x86_64/results.tsv"
	printf 'bravo\t1.0\tok\n' > "$_gf_wd/ts/b/build-results-x86_64/results.tsv"
	printf 'charlie\t1.0\tok\n' > "$_gf_wd/ts/c/build-results-x86_64/results.tsv"
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/ts.xml" "$_gf_wd/ts/a" 200 2026-09-20T08:00:00Z "$_gf_wd/srcpkgs" >/dev/null
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/ts.xml" "$_gf_wd/ts/b" 201 2026-09-20T12:00:00Z "$_gf_wd/srcpkgs" >/dev/null
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/ts.xml" "$_gf_wd/ts/c" 202 2026-09-20T06:00:00Z "$_gf_wd/srcpkgs" >/dev/null
	it 'ISO run date: pubDate keeps the time of day'
	grep -q '<pubDate>Sun, 20 Sep 2026 08:00:00 +0000</pubDate>' "$_gf_wd/ts.xml"; assert_rc $? 0
	it 'ISO run date: description shows the bare date only'
	grep -q 'Built on: 2026-09-20' "$_gf_wd/ts.xml"; assert_rc $? 0
	it 'same-day items sort newest first'
	assert_eq "$(_titles "$_gf_wd/ts.xml")" 'bravo alpha charlie'

	mkdir -p "$_gf_wd/leg/build-results-x86_64"
	printf 'legacy\t1.0\tok\n' > "$_gf_wd/leg/build-results-x86_64/results.tsv"
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/leg.xml" "$_gf_wd/leg" 300 2026-09-20 "$_gf_wd/srcpkgs" >/dev/null
	it 'legacy date-only run date means midnight UTC'
	grep -q '<pubDate>Sun, 20 Sep 2026 00:00:00 +0000</pubDate>' "$_gf_wd/leg.xml"; assert_rc $? 0

	mkdir -p "$_gf_wd/mix/old/build-results-x86_64" \
		"$_gf_wd/mix/new/build-results-x86_64"
	printf 'zzz\t1.0\tok\n' > "$_gf_wd/mix/old/build-results-x86_64/results.tsv"
	printf 'aaa\t1.0\tok\n' > "$_gf_wd/mix/new/build-results-x86_64/results.tsv"
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/mix.xml" "$_gf_wd/mix/old" 400 2026-09-20T08:00:00Z "$_gf_wd/srcpkgs" >/dev/null
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/mix.xml" "$_gf_wd/mix/new" 401 2026-09-21 "$_gf_wd/srcpkgs" >/dev/null
	it 'legacy midnight item still sorts by its own date'
	assert_eq "$(_titles "$_gf_wd/mix.xml")" 'aaa zzz'

	mkdir -p "$_gf_wd/off/a/build-results-x86_64" \
		"$_gf_wd/off/b/build-results-x86_64"
	printf 'zzz\t1.0\tok\n' > "$_gf_wd/off/a/build-results-x86_64/results.tsv"
	printf 'aaa\t1.0\tok\n' > "$_gf_wd/off/b/build-results-x86_64/results.tsv"
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/off.xml" "$_gf_wd/off/a" 500 2026-09-20T09:00:00Z "$_gf_wd/srcpkgs" >/dev/null
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/off.xml" "$_gf_wd/off/b" 501 2026-09-20T12:00:00+02:00 "$_gf_wd/srcpkgs" >/dev/null
	it 'numeric offset: kept in pubDate'
	grep -q '<pubDate>Sun, 20 Sep 2026 12:00:00 +0200</pubDate>' "$_gf_wd/off.xml"; assert_rc $? 0
	it 'numeric offset: sorts by instant, not wall clock'
	assert_eq "$(_titles "$_gf_wd/off.xml")" 'aaa zzz'

	mkdir -p "$_gf_wd/junk/build-results-x86_64"
	printf 'junked\t1.0\tok\n' > "$_gf_wd/junk/build-results-x86_64/results.tsv"
	python3 "$SCRIPT_DIR/src/gen-feed.py" update \
		"$_gf_wd/junk.xml" "$_gf_wd/junk" 600 "not-a-date" "$_gf_wd/srcpkgs" >/dev/null
	it 'unparsable run date: falls back to now instead of aborting'
	grep -q "<pubDate>[A-Za-z]*, [0-9][0-9] [A-Za-z]* $(date -u +%Y) " \
		"$_gf_wd/junk.xml"; assert_rc $? 0

	rm -rf "$_gf_wd"
else
	echo '  (skipped: python3 not on PATH)'
fi

echo '== _check_nocross_chain =='

eval "$(awk '
  /^[[:space:]]*_check_nocross_chain\(\)/ { p=1; depth=0 }
  p { print }
  p && /\{/ { depth++ }
  p && /\}/ { depth--; if (depth==0) p=0 }
' "$SCRIPT_DIR/.github/workflows/build.yml")"

_mknc_tpl() {
  local _name="$1"; shift
  mkdir -p "srcpkgs/${_name}"
  : > "srcpkgs/${_name}/template"
  while [ $# -gt 0 ]; do
    printf '%s\n' "$1" >> "srcpkgs/${_name}/template"
    shift
  done
}

it 'missing template returns 1'
rm -rf srcpkgs/ghost
_cnc_visited=""
_check_nocross_chain ghost; assert_rc $? 1

it 'direct nocross returns 0'
_mknc_tpl nc1 'nocross=yes'
_cnc_visited=""
_check_nocross_chain nc1; assert_rc $? 0

it 'no nocross no deps returns 1'
_mknc_tpl plain1
_cnc_visited=""
_check_nocross_chain plain1; assert_rc $? 1

it 'dep via hostmakedepends with nocross returns 0'
_mknc_tpl nc_dep 'nocross=yes'
_mknc_tpl pkg_hmd "hostmakedepends=\"nc_dep\""
_cnc_visited=""
_check_nocross_chain pkg_hmd; assert_rc $? 0

it 'dep via makedepends with nocross returns 0'
_mknc_tpl nc_dep2 'nocross=yes'
_mknc_tpl pkg_mkd "makedepends=\"nc_dep2\""
_cnc_visited=""
_check_nocross_chain pkg_mkd; assert_rc $? 0

it 'dep via depends with nocross returns 0'
_mknc_tpl nc_dep3 'nocross=yes'
_mknc_tpl pkg_dep "depends=\"nc_dep3\""
_cnc_visited=""
_check_nocross_chain pkg_dep; assert_rc $? 0

it 'transitive chain (3 deep) returns 0'
_mknc_tpl nc_leaf 'nocross=yes'
_mknc_tpl chain_b "hostmakedepends=\"nc_leaf\""
_mknc_tpl chain_a "hostmakedepends=\"chain_b\""
_cnc_visited=""
_check_nocross_chain chain_a; assert_rc $? 0

it 'versioned dep (>=) stripped correctly'
_mknc_tpl nc_ver 'nocross=yes'
_mknc_tpl pkg_ver "hostmakedepends=\"nc_ver>=1.0\""
_cnc_visited=""
_check_nocross_chain pkg_ver; assert_rc $? 0

it 'circular dep without nocross returns 1 (no infinite loop)'
_mknc_tpl circ_a "hostmakedepends=\"circ_b\""
_mknc_tpl circ_b "hostmakedepends=\"circ_a\""
_cnc_visited=""
_check_nocross_chain circ_a; assert_rc $? 1

it 'external dep (no template) skipped, returns 1'
_mknc_tpl pkg_ext "hostmakedepends=\"no-such-pkg\""
_cnc_visited=""
_check_nocross_chain pkg_ext; assert_rc $? 1

it 'visited guard prevents re-entry'
_mknc_tpl pkg_guard
_cnc_visited=" pkg_guard"
_check_nocross_chain pkg_guard; assert_rc $? 1

echo
echo '== close-update-issues.py =='

if command -v python3 >/dev/null 2>&1; then
	_cui_wd=$(mktemp -d)
	mkdir -p "$_cui_wd/results/build-results-x86_64" \
		"$_cui_wd/results/build-results-aarch64"
	printf 'zen-browser-bin\t1.22.1\tok\nz-fail\t1.0\tok\nbump\t3.2.1\tskip\n' \
		> "$_cui_wd/results/build-results-x86_64/results.tsv"
	printf 'zen-browser-bin\t1.22.1\tok\nz-fail\t1.0\tfail\nbump\t3.2.1\tok\n' \
		> "$_cui_wd/results/build-results-aarch64/results.tsv"

	it 'results: ok/fail versions collected per pkg'
	assert_eq "$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cui", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
ok, fail = m.collect_results(sys.argv[2])
print("zok=" + ",".join(sorted(ok.get("zen-browser-bin", []))))
print("zfail=" + ",".join(sorted(fail.get("z-fail", []))))
print("bump=" + ",".join(sorted(ok.get("bump", []))))
' "$SCRIPT_DIR/src/close-update-issues.py" "$_cui_wd/results")" "$(printf 'zok=1.22.1\nzfail=1.0\nbump=3.2.1')"

	it 'issue body: hidden markers + heading fallback parsed'
	assert_eq "$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cui", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
body = "**Package:** `zen-browser-bin`\n\n**Upstream version:** `1.22.1`\n\n<!-- package-update:zen-browser-bin -->\n<!-- upstream-version:1.22.1 -->"
print(m.extract_pkg_version(body))
' "$SCRIPT_DIR/src/close-update-issues.py")" "('zen-browser-bin', '1.22.1')"

	it 'issue body: scan format is parsed by both package/version marker and heading parsers'
	assert_eq "$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cui", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
body = "**Package:** `foo`\n**Upstream version:** `2.0`\n<!-- package-update:foo -->\n<!-- upstream-version:2.0 -->"
print(m.extract_pkg_version(body))
' "$SCRIPT_DIR/src/close-update-issues.py")" "('foo', '2.0')"

	it 'autobump skip/done marker is bound to requested version'
	assert_eq "$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cui", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
comments = [{"body": "<!-- autobump:skip for 1.2 -->"}]
print("%s,%s,%s" % (m.has_skip_marker(comments, "1.2"),
                    m.has_skip_marker(comments, "1.3"),
                    m.has_skip_marker(comments, "")))
' "$SCRIPT_DIR/src/close-update-issues.py")" 'True,False,False'

	it 'autobump:no marker remains version-independent'
	assert_eq "$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cui", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.has_skip_marker([{"body": "<!-- autobump:no -->"}], "1.2"))
' "$SCRIPT_DIR/src/close-update-issues.py")" 'True'

	it 'issue body: no markers returns None,None'
	assert_eq "$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cui", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.extract_pkg_version("no markers here"))
' "$SCRIPT_DIR/src/close-update-issues.py")" '(None, None)'

	it 'results: missing dir yields empty maps, no crash'
	assert_eq "$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cui", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.collect_results(sys.argv[2]) == ({}, {}))
' "$SCRIPT_DIR/src/close-update-issues.py" "$_cui_wd/nope")" "True"

	it 'cli: --help exits 0'
	python3 "$SCRIPT_DIR/src/close-update-issues.py" --help >/dev/null 2>&1
	assert_rc $? 0

	it 'cli: results_dir required unless --list-stale'
	python3 "$SCRIPT_DIR/src/close-update-issues.py" \
		--repo o/r --list-stale >/dev/null 2>&1
	assert_rc $? 2

	it 'cmp_versions: dash revision, zero padding and rc suffix'
	assert_eq "$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cui", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
cases = [("157.0.1.1", "157.0-1"), ("157.0.1.1", "157.0.1-1"),
         ("1.0", "1.0.0"), ("1.0", "1.0.00"), ("1.0", "1.0-rc1"),
         ("1.9", "1.10"), ("1.23.2", "1.23.1")]
print(";".join(str(m.cmp_versions(a, b)) for a, b in cases))
' "$SCRIPT_DIR/src/close-update-issues.py")" '1;0;0;0;1;-1;1'

	it 'shipped_versions: keys on dir name, pkgname and symlink target'
	assert_eq "$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cui", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
sv = m.shipped_versions(sys.argv[2])
print(sorted(k for k in sv if k.startswith("fcitx5-lotus")))
' "$SCRIPT_DIR/src/close-update-issues.py" "$SCRIPT_DIR/srcpkgs")" \
		"['fcitx5-lotus', 'fcitx5-lotus-settings']"
else
	echo '  (skipped: python3 not on PATH)'
fi

echo '== workflows: Surfer CLI only, no WebDAV =='

# Deletes now go through the surfer CLI (REST /api/files/, fsPromises.rm), so
# they cannot crash Surfer the way the removed WebDAV DELETE did. What must
# stay true is that the workflows delegate to ocoman and never hand-roll a
# DELETE, and that the workaround flags are gone for good.
it 'cleanup.yml does not use the surfer CLI del command'
assert_eq "$(grep -c 'surfer .* del \| \bdel ' "$SCRIPT_DIR/.github/workflows/cleanup.yml" 2>/dev/null)" '0'

it 'cleanup.yml delegates to ocoman prune (no DELETE)'
assert_eq "$(grep -c './ocoman -p' "$SCRIPT_DIR/.github/workflows/cleanup.yml")" '1'
assert_eq "$(grep -v '^[[:space:]]*#' "$SCRIPT_DIR/.github/workflows/cleanup.yml" | grep -c 'SURF_SKIP_DELETE=0\|xargs.*del\|surfer.*del\|\bdel\b')" '0'

it 'build.yml calls cleanup.yml for removed packages'
assert_eq "$(grep -c 'uses: \./\.github/workflows/cleanup\.yml' "$SCRIPT_DIR/.github/workflows/build.yml")" '1'
assert_eq "$(grep -c 'SURF_SKIP_DELETE: .0' "$SCRIPT_DIR/.github/workflows/build.yml")" '0'

it 'cleanup.yml has no schedule trigger (event-driven only)'
assert_eq "$(grep -c '^  *schedule:' "$SCRIPT_DIR/.github/workflows/cleanup.yml")" '0'
assert_eq "$(grep -c '^  *cron:' "$SCRIPT_DIR/.github/workflows/cleanup.yml")" '0'
# ...but it must stay callable from build.yml
assert_eq "$(grep -c 'workflow_call:' "$SCRIPT_DIR/.github/workflows/cleanup.yml")" '1'
assert_eq "$(grep -c 'workflow_dispatch:' "$SCRIPT_DIR/.github/workflows/cleanup.yml")" '1'

it 'cleanup.yml carries none of the removed delete workarounds'
# The flags are gone from ocoman; a leftover would silently do nothing.
assert_eq "$(grep -c 'SURF_SKIP_DELETE' "$SCRIPT_DIR/.github/workflows/cleanup.yml"; true)" '0'
assert_eq "$(grep -c 'SURF_DELETE_ORPHANS' "$SCRIPT_DIR/.github/workflows/cleanup.yml"; true)" '0'
assert_eq "$(grep -c 'SURF_BACKEND' "$SCRIPT_DIR/.github/workflows/cleanup.yml"; true)" '0'
# ...and ocoman itself must not know them either
assert_eq "$(grep -c 'SURF_SKIP_DELETE\|SURF_DELETE_ORPHANS\|SURF_BACKEND' "$SCRIPT_DIR/ocoman"; true)" '0'

it 'cleanup.yml calls ocoman -p with no positional argument'
# getopts' p) takes no argument, so anything after -p was silently discarded
assert_eq "$(grep -c '\./ocoman -p \${{' "$SCRIPT_DIR/.github/workflows/cleanup.yml")" '0'
assert_eq "$(grep -c '\./ocoman -p$' "$SCRIPT_DIR/.github/workflows/cleanup.yml")" '1'
# ARCH must come from the job env instead
assert_eq "$(grep -c 'ARCH: \${{ matrix\.arch }}' "$SCRIPT_DIR/.github/workflows/cleanup.yml")" '1'

it 'cleanup.yml cannot hang for hours on a dead Surfer'
assert_eq "$(grep -c '^    timeout-minutes: [0-9]' "$SCRIPT_DIR/.github/workflows/cleanup.yml")" '1'

echo '== surf transport: surfer CLI backend =='

# ocoman reaches Surfer only through the @cloudron/surfer CLI, so every case
# below drives the real ocoman helpers against a scripted fake surfer. The CLI
# reads its credentials from $HOME/.surfer.json only (cli/config.js has no env
# support), so an un-isolated HOME would clobber -- or read -- the maintainer's
# actual credentials. Isolate it.
_CLI_HOME=$(mktemp -d)
_HOME_BACKUP="${HOME:-}"
PATH="$_FAKE_BIN:$PATH_BACKUP"
export PATH
export SURFER_TOKEN=dummy SURFER_USER=dummy-user

cat > "$_FAKE_BIN/surfer" <<'EOF'
#!/bin/sh
# Scripted fake surfer. One directive per line in $FAKE_SURFER_SCRIPT:
#   listing:<file>  print 'Entries:' plus the tab-indented paths in <file>,
#                   exactly as the CLI formats a directory listing
#   empty          'Empty directory.' (rc 0)
#   missing        'No such file or directory' (rc 1) -- a 404
#   token          'Invalid username or password' (rc 1) -- a 401
#   connect        'Failed to connect to server: ...' (rc 1) -- transport
#   bytes:<file>   print that file's contents (rc 0) -- a raw download
#   fail           print 'boom' (rc 1)
# The real CLI prints errors on stdout, so the fakes must too, and it prints
# "Using server <url>" on stderr on every call (cli/actions.js checkConfig),
# so the fake mirrors that as well.
[ -n "${FAKE_SURFER_ARGV:-}" ] && printf '%s\n' "$*" >> "$FAKE_SURFER_ARGV"
printf 'Using server %s\n' "$SURFER_URL" >&2
_n=$(cat "${FAKE_SURFER_COUNT:-/dev/null}" 2>/dev/null) || _n=0
[ -n "$_n" ] || _n=0
_n=$((_n + 1))
printf '%s' "$_n" > "$FAKE_SURFER_COUNT"
_line=$(sed -n "${_n}p" "$FAKE_SURFER_SCRIPT")
[ -n "$_line" ] || _line=$(tail -n 1 "$FAKE_SURFER_SCRIPT")
case "$_line" in
	listing:*)
		echo 'Entries:'
		while IFS= read -r _e; do
			[ -n "$_e" ] || continue
			printf '\t%s\n' "$_e"
		done < "${_line#listing:}"
		exit 0 ;;
	empty)
		echo 'Empty directory.'
		exit 0 ;;
	missing)
		echo 'No such file or directory'
		exit 1 ;;
	token)
		echo 'Invalid username or password'
		exit 1 ;;
	connect)
		echo 'Failed to connect to server: connect ECONNREFUSED'
		exit 1 ;;
	bytes:*)
		cat "${_line#bytes:}"
		exit 0 ;;
	fail)
		echo 'boom'
		exit 1 ;;
esac
exit 0
EOF
chmod +x "$_FAKE_BIN/surfer"

_SARGV=$(mktemp)
_SSCRIPT=$(mktemp)
_SCOUNT=$(mktemp)
_LISTING=$(mktemp)
_REPO_BODY=$(mktemp)
_repodate_member="$_TEST_TMP/index.plist"
printf '<plist version="1.0"><dict/></plist>' > "$_repodate_member"
tar -cf "$_REPO_BODY" -C "$_TEST_TMP" index.plist

# The fake reads its script and its invocation counter from these; keep them
# exported for the whole section so no case has to remember to set them.
export FAKE_SURFER_ARGV="$_SARGV" FAKE_SURFER_SCRIPT="$_SSCRIPT" FAKE_SURFER_COUNT="$_SCOUNT"

# Each case starts from "not initialised yet", like a fresh ocoman run.
_cli_reset() {
	_SURF_READY=''
	HOME="$_CLI_HOME"
	export HOME
	: > "$_SARGV"
	printf '0' > "$_SCOUNT"
}

_cli_reset
it 'PATH resolves to the fake CLI'
assert_eq "$(command -v surfer)" "$_FAKE_BIN/surfer"

_cli_reset
it 'surf_cli_init accepts an installed CLI with credentials'
surf_cli_init >/dev/null 2>&1; _rc=$?
assert_rc "$_rc" 0
assert_eq "$_SURF_READY" '1'

it 'surf_cli_init writes ~/.surfer.json'
assert_eq "$(grep -c '"username": "dummy-user"' "$_CLI_HOME/.surfer.json")" '1'
it '...including the app password'
assert_eq "$(grep -c '"password": "dummy"' "$_CLI_HOME/.surfer.json")" '1'
it '...pointed at SURFER_URL'
assert_eq "$(grep -c '"server": "https://repo.osowoso.org"' "$_CLI_HOME/.surfer.json")" '1'
it 'the config is not readable by other users'
# The app password must not be world-readable on the runner.
assert_eq "$(stat -c '%a' "$_CLI_HOME/.surfer.json")" '600'

it 'the password never reaches the process list'
# grep -c prints 0 and exits 1 on no match, so read the count without a
# fallback that would append a second line.
assert_eq "$(grep -c 'dummy' "$_SARGV" 2>/dev/null; true)" '0'

_cli_reset
it 'a missing surfer CLI is fatal'
# Not "move the fake aside": this host may carry a real surfer in PATH, and
# the failure has to hold even so.
out=$(PATH=/nonexistent surf_cli_init 2>&1); _rc=$?
PATH="$_FAKE_BIN:$PATH_BACKUP"; export PATH
assert_rc "$_rc" 1
it '...and says so'
case "$out" in
	*'not in PATH'*) assert_eq 'ok' 'ok' ;;
	*) assert_eq "$out" 'a message naming PATH' ;;
esac

_cli_reset
it 'missing credentials are fatal'
out=$(SURFER_USER='' SURFER_TOKEN='' surf_cli_init 2>&1); _rc=$?
assert_rc "$_rc" 1
it '...and an empty username is named as the problem'
case "$out" in
	*'SURFER_USER'*) assert_eq 'ok' 'ok' ;;
	*) assert_eq "$out" 'a message naming SURFER_USER' ;;
esac

_cli_reset
it 'an empty app password is fatal'
out=$(SURFER_TOKEN='' surf_cli_init 2>&1); _rc=$?
assert_rc "$_rc" 1
it '...and is named as the problem'
case "$out" in
	*'SURFER_TOKEN'*) assert_eq 'ok' 'ok' ;;
	*) assert_eq "$out" 'a message naming SURFER_TOKEN' ;;
esac

printf '/x86_64/foo-1.0_1.x86_64.xbps\n/x86_64/bar-2.0_1.x86_64.xbps\n/x86_64/subdir/\n' > "$_LISTING"
printf 'listing:%s\n' "$_LISTING" > "$_SSCRIPT"
_cli_reset
printf 'listing:%s\n' "$_LISTING" > "$_SSCRIPT"
it 'fetch_remote_list parses a listing into basenames'
_list=$(fetch_remote_list '/x86_64'); _rc=$?
assert_rc "$_rc" 0
assert_eq "$_list" "$(printf 'foo-1.0_1.x86_64.xbps\nbar-2.0_1.x86_64.xbps')"
it '...passing the API-relative path straight through'
assert_eq "$(cat "$_SARGV")" 'get /x86_64'
it '...and skipping the directory entry'
assert_eq "$(printf '%s\n' "$_list" | grep -c 'subdir'; true)" '0'

printf 'empty\n' > "$_SSCRIPT"
_cli_reset
printf 'empty\n' > "$_SSCRIPT"
it 'fetch_remote_list treats an empty directory as no packages'
_list=$(fetch_remote_list '/x86_64' 2>/dev/null); _rc=$?
assert_rc "$_rc" 0
assert_eq "$_list" ''

printf 'missing\n' > "$_SSCRIPT"
_cli_reset
printf 'missing\n' > "$_SSCRIPT"
it 'fetch_remote_list treats a 404 as no packages, not a failure'
_list=$(fetch_remote_list '/x86_64' 2>/dev/null); _rc=$?
assert_rc "$_rc" 0
assert_eq "$_list" ''

printf 'connect\n' > "$_SSCRIPT"
_cli_reset
printf 'connect\n' > "$_SSCRIPT"
it 'fetch_remote_list fails on a transport error'
fetch_remote_list '/x86_64' >/dev/null 2>&1; _rc=$?
if [ "$_rc" -eq 0 ]; then
	assert_eq 'reported success on a dead host' 'nonzero rc'
else
	assert_eq 'ok' 'ok'
fi

_out="$_TEST_TMP/repodata.out"
printf 'bytes:%s\n' "$_REPO_BODY" > "$_SSCRIPT"
_cli_reset
printf 'bytes:%s\n' "$_REPO_BODY" > "$_SSCRIPT"
it 'fetch_repodata downloads the index'
fetch_repodata '/x86_64/x86_64-repodata' "$_out" 2>/dev/null; _rc=$?
assert_rc "$_rc" 0
assert_eq "$(tar -tf "$_out" 2>/dev/null | head -n1)" 'index.plist'
it '...from the API-relative path'
assert_eq "$(tail -n 1 "$_SARGV")" 'get /x86_64/x86_64-repodata'

_JUNK_BODY=$(mktemp)
printf 'not an index at all\n' > "$_JUNK_BODY"
printf 'bytes:%s\n' "$_JUNK_BODY" > "$_SSCRIPT"
_cli_reset
printf 'bytes:%s\n' "$_JUNK_BODY" > "$_SSCRIPT"
it 'fetch_repodata rejects a payload that is not an index'
SURF_DEADLINE=0 fetch_repodata '/x86_64/x86_64-repodata' "$_out" 2>/dev/null; _rc=$?
SURF_DEADLINE=1500
assert_rc "$_rc" 2
it '...and leaves no payload behind'
assert_eq "$([ -e "$_out" ] && echo present || echo absent)" 'absent'
rm -f "$_JUNK_BODY"

printf 'missing\n' > "$_SSCRIPT"
_cli_reset
printf 'missing\n' > "$_SSCRIPT"
it 'a missing index reports "first run", not an error'
fetch_repodata '/x86_64/x86_64-repodata' "$_out" 2>/dev/null; _rc=$?
assert_rc "$_rc" 1
it '...and leaves no partial file behind'
assert_eq "$([ -e "$_out" ] && echo present || echo absent)" 'absent'

printf 'token\n' > "$_SSCRIPT"
_cli_reset
printf 'token\n' > "$_SSCRIPT"
it 'rejected credentials give up immediately'
SURF_DEADLINE=0 fetch_repodata '/x86_64/x86_64-repodata' "$_out" 2>/dev/null; _rc=$?
SURF_DEADLINE=1500
assert_rc "$_rc" 2
it '...after a single attempt, not a retry storm'
assert_eq "$(cat "$_SCOUNT")" '1'

printf 'connect\n' > "$_SSCRIPT"
_cli_reset
printf 'connect\n' > "$_SSCRIPT"
printf '1' > "$_SCOUNT"
it 'a transport error is retried until the deadline'
SURF_DEADLINE=0 fetch_repodata '/x86_64/x86_64-repodata' "$_out" 2>/dev/null; _rc=$?
SURF_DEADLINE=1500
assert_rc "$_rc" 2

_pkg="$_TEST_TMP/foo-1.0_1.x86_64.xbps"
: > "$_pkg"
_cli_reset
printf 'ok\n' > "$_SSCRIPT"
it 'upload_file uploads into the destination directory'
upload_file "$_pkg" '/x86_64' >/dev/null 2>&1; _rc=$?
assert_rc "$_rc" 0
it '...with a trailing-slash directory, as "put" requires'
assert_eq "$(cat "$_SARGV")" "put $_pkg /x86_64/"
it '...and never with -d, which would purge files we did not upload'
assert_eq "$(grep -c -- ' -d' "$_SARGV" 2>/dev/null; true)" '0'
_cli_reset
printf 'ok\n' > "$_SSCRIPT"
it 'delete_remote always reaches the server'
delete_remote '/x86_64/foo-1.0_1.x86_64.xbps' >/dev/null 2>&1; _rc=$?
assert_rc "$_rc" 0
assert_eq "$(cat "$_SARGV")" 'del -y /x86_64/foo-1.0_1.x86_64.xbps'
it '...and never leaves the delete without -y to skip the prompt'
assert_eq "$(grep -c '^del -y ' "$_SARGV"; true)" '1'
it '...and issues no MKCOL, which the CLI does not have'
assert_eq "$(grep -ci 'mkcol' "$_SARGV"; true)" '0'

# End to end through the fake: the delete_remote stub from the prune_orphans
# section is gone, so this drives the real one into surfer del.
_orphan_list=$(mktemp)
printf 'gone\n' > "$_orphan_list"
_cli_reset
printf 'ok\n' > "$_SSCRIPT"
it 'delete_orphan_files removes orphan binaries through the CLI'
delete_orphan_files "$_orphan_list" "$(printf '%s\n' \
	'gone-1.0_1.x86_64.xbps' \
	'keepme-1.0_1.x86_64.xbps')" >/dev/null 2>&1
assert_eq "$(cat "$_SARGV")" "$(printf 'del -y /x86_64/gone-1.0_1.x86_64.xbps\ndel -y /x86_64/gone-1.0_1.x86_64.xbps.sig2')"
it '...leaving a package that still has a template alone'
assert_eq "$(grep -c 'keepme' "$_SARGV"; true)" '0'
rm -f "$_orphan_list"

# Leave no trace: the fake config file and the isolated HOME go away with
# the section, and the next section starts from an uninitialised CLI again.
rm -rf "$_CLI_HOME"
HOME="$_HOME_BACKUP"
export HOME
_SURF_READY=''
unset FAKE_SURFER_ARGV FAKE_SURFER_SCRIPT FAKE_SURFER_COUNT

echo
printf 'Passed: %s    Failed: %s\n' "$_PASS" "$_FAIL"
[ "$_FAIL" -eq 0 ] || exit 1
