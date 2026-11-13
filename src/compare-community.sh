#!/usr/bin/env bash
#
# compare-community.sh - compare the binary package contents of the oco
# community repository against the other Void community repositories.
#
# Builds a persistent package database (TSV) plus per-arch merged repodata
# in a state directory, and prints a comparison table.
#
# The repository registry is derived by SOURCING
# srcpkgs/Community-Repositories-Collection/template, so this script never
# hardcodes a URL: editing that template changes what is scanned here too.
#
# The official Void repositories are included as a comparison baseline but
# are deliberately NOT part of the merged repodata -- every system already
# has them, and merging 14k upstream packages would swamp oco's ~260.

set -o pipefail

PROGNAME="${0##*/}"
REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TEMPLATE="${REPO_ROOT}/srcpkgs/Community-Repositories-Collection/template"
DUMP="${REPO_ROOT}/src/repodata-dump.py"

SURFER_URL="https://repo.osowoso.org"
VOID_URL="https://repo-default.voidlinux.org"

STATE="${OCO_COMPARE_STATE:-/dev/shm/oco-compare}"
ARCHES="x86_64 x86_64-musl aarch64 aarch64-musl"
REPOS_FILTER=""
DO_FETCH=1
DO_JSON=0
DO_REPORT=0
JOBS="${OCO_COMPARE_JOBS:-8}"

_rc=0

usage() {
	cat <<-EOF
	Usage: $PROGNAME [OPTIONS]

	Compare binary package contents across the oco and Void community
	repositories, using a persistent TSV database and per-arch merged
	repodata kept in the state directory.

	Options:
	  --state-dir PATH   where the database and caches live
	                     (default: \$OCO_COMPARE_STATE or /dev/shm/oco-compare)
	  --arches "LIST"    space separated architectures to probe
	                     (default: "$ARCHES")
	  --repos "LIST"     comma separated repository names, for a fast dry run
	  --no-fetch         reuse the cache only, do not hit the network
	  --json             also write reports/compare-<ts>.json
	  --report           also write markdown and self-contained HTML reports
	  -h, --help         show this help

	Exit status:
	  0  every repository/arch pair is ok or absent
	  1  at least one pair is bad or errored, or a self-check failed
	  2  usage or state directory error

	Note: the merged repodata is a RAM-local scratch artifact. Never upload
	it to repo.osowoso.org -- it is unsigned and not built for release.
	EOF
}

_msg() {
	printf '::%s:: %s\n' "${1:-info}" "${2}"
	return 0
}

_die() {
	printf '::error:: %s\n' "${2}" >&2
	exit "${1:-2}"
}

_need() {
	command -v "$1" >/dev/null 2>&1 || _die 2 "missing required tool: $1"
}

# ---------------------------------------------------------------- arguments

_parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--state-dir)
			[ $# -ge 2 ] || _die 2 "--state-dir needs a value"
			STATE="$2"
			shift 2
			;;
		--arches)
			[ $# -ge 2 ] || _die 2 "--arches needs a value"
			ARCHES="$2"
			shift 2
			;;
		--repos)
			[ $# -ge 2 ] || _die 2 "--repos needs a value"
			REPOS_FILTER="$2"
			shift 2
			;;
		--no-fetch) DO_FETCH=0; shift ;;
		--json) DO_JSON=1; shift ;;
		--report) DO_REPORT=1; shift ;;
		-h|--help)
			usage
			exit 0
			;;
		*) usage >&2; _die 2 "unknown option: $1" ;;
		esac
	done
}

# ------------------------------------------------------------------ registry

# Emit "name<TAB>url<TAB>homepage<TAB>archs" for every CRC subpackage, as
# resolved for XBPS_TARGET_MACHINE=$1.
#
# The template is shell, not data: each CRC-<name>_package() sets archs /
# homepage / short_desc and defines a nested pkg_install() that writes the
# xbps.d conf. Sourcing it and calling the functions reproduces exactly what
# xbps would install, including the two `case "${XBPS_TARGET_MACHINE}"` blocks.
_crc_collect() {
	bash -s -- "$1" "$TEMPLATE" "$STATE/.tmp" <<-'_CRC_EOF'
		set -e
		_machine="$1"
		_template="$2"
		_dest="$3"

		export XBPS_TARGET_MACHINE="$_machine"
		export PKGDESTDIR="${_dest}/d77"
		rm -rf "$PKGDESTDIR"
		mkdir -p "$PKGDESTDIR"

		# xbps provides vmkdir; the template only needs this one helper.
		vmkdir() { mkdir -p "${PKGDESTDIR}/$1"; }

		# shellcheck source=/dev/null
		. "$_template"

		for _fn in $(declare -F | awk '{print $3}' | grep '^CRC-.*_package$' | sort); do
			_name="${_fn%_package}"
			_name="${_name#CRC-}"
			# archs/homepage/short_desc are plain globals in the template;
			# reset them so one subpackage cannot inherit another's values.
			archs=""
			homepage=""
			short_desc=""
			rm -rf "${PKGDESTDIR}/etc/xbps.d"
			"$_fn"
			# pkg_install was defined by the call above; it is a global
			# function in bash once the outer function returns.
			pkg_install
			_conf="${PKGDESTDIR}/etc/xbps.d/20-CRC-${_name}.conf"
			[ -f "$_conf" ] || continue
			_url="$(sed -n 's/^repository=//p' "$_conf" | head -n 1)"
			[ -n "$_url" ] || continue
			printf '%s\t%s\t%s\t%s\n' "$_name" "$_url" "$homepage" "$archs"
		done
	_CRC_EOF
}

# Build the job list: one line per (repo, arch) that claims to be available.
# Writes $STATE/.jobs and $STATE/repos.tsv.
_registry_build() {
	local _machine _line _name _url _homepage _archs _pat _pats _arch _sel _want _job_url
	local _registry="${STATE}/.registry"
	local _jobs="${STATE}/.jobs"

	: >"$_registry"
	: >"$_jobs"

	# Registry columns: name, machine, url, homepage, archs.
	#
	# `machine` records WHICH machine a URL was resolved for. The CRC
	# template builds its URL from ${XBPS_TARGET_MACHINE} (and two of the
	# 18 switch on it in a `case`), so black-hole on x86_64 and black-hole
	# on aarch64 are genuinely different URLs. Collapsing the rows by name
	# alone would silently reuse the x86_64 URL on every arch. `*` means
	# arch-independent, i.e. the URL still carries an {arch} placeholder.
	#
	# oco itself, then the CRC repos, then the official Void baseline.
	{
		printf 'oco\t*\t%s/{arch}\thttps://repo.osowoso.org\t*\n' "$SURFER_URL"
		local _m
		for _m in $ARCHES; do
			_crc_collect "$_m" |
				while IFS=$'\t' read -r _n _u _h _a; do
					[ -n "$_n" ] || continue
					printf '%s\t%s\t%s\t%s\t%s\n' "$_n" "$_m" "$_u" "$_h" "$_a"
				done
		done
		# The official repos store <arch>-repodata directly in the
		# variant directory, so the base carries no {arch}: xbps appends
		# /<machine>-repodata to whatever we hand it.
		printf 'void-current\t*\t%s/current\thttps://voidlinux.org\t*\n' "$VOID_URL"
		printf 'void-multilib\t*\t%s/current/multilib\thttps://voidlinux.org\t*\n' "$VOID_URL"
		printf 'void-nonfree\t*\t%s/current/nonfree\thttps://voidlinux.org\t*\n' "$VOID_URL"
		printf 'void-multilib-nonfree\t*\t%s/current/multilib/nonfree\thttps://voidlinux.org\t*\n' "$VOID_URL"
	} >"$_registry"

	# Deduplicate per (name, machine) pair.
	local _seen=""
	: >"${_registry}.uniq"
	while IFS=$'\t' read -r _name _machine _url _homepage _archs; do
		[ -n "$_name" ] || continue
		case "$_seen" in
		*" $_name $_machine "*) continue ;;
		esac
		_seen="${_seen} $_name $_machine "
		printf '%s\t%s\t%s\t%s\t%s\n' "$_name" "$_machine" "$_url" "$_homepage" "$_archs" >>"${_registry}.uniq"
	done <"$_registry"
	mv "${_registry}.uniq" "$_registry"

	if [ -n "$REPOS_FILTER" ]; then
		_sel=" $(printf '%s' "$REPOS_FILTER" | tr ',' ' ') "
		local _filtered="${_registry}.f"
		: >"$_filtered"
		while IFS=$'\t' read -r _name _rest; do
			case "$_sel" in
			*" $_name "*) printf '%s\t%s\n' "$_name" "$_rest" >>"$_filtered" ;;
			esac
		done <"$_registry"
		mv "$_filtered" "$_registry"
	fi

	while IFS=$'\t' read -r _name _machine _url _homepage _archs; do
		[ -n "$_name" ] || continue
		# Split on whitespace WITHOUT glob expansion. An unquoted
		# `for _pat in $_archs` expands a bare `*` against the current
		# directory into filenames, so every row declared `archs=*`
		# (oco and the four void rows) would silently match no arch.
		read -r -a _pats <<<"$_archs"
		for _arch in $ARCHES; do
			# A CRC row was resolved for one specific machine; emit it
			# only for that machine. `*` rows expand for every arch.
			if [ "$_machine" != '*' ] && [ "$_machine" != "$_arch" ]; then
				continue
			fi
			# `archs` in the template are globs: x86_64* covers
			# x86_64-musl, aarch64* both aarch64 variants. Match, do not
			# prefix-test.
			_want=""
			for _pat in "${_pats[@]}"; do
				case "$_pat" in
				'*')
					_want=1
					break
					;;
				*'*'*)
					# shellcheck disable=SC2053
					if [[ "$_arch" == $_pat ]]; then
						_want=1
						break
					fi
					;;
				*)
					if [ "$_arch" = "$_pat" ]; then
						_want=1
						break
					fi
					;;
				esac
			done
			[ -n "$_want" ] || continue
			# Expand into a NEW variable: assigning back to $_url
			# would consume the placeholder on the first arch, so every
			# later arch would reuse the first arch's URL.
			_job_url="${_url//\{arch\}/$_arch}"
			_job_url="${_job_url%/}"
			printf '%s\t%s\t%s\t%s\t%s\n' "$_name" "$_arch" "$_job_url" "$_homepage" "$_archs" >>"$_jobs"
		done
	done <"$_registry"
}

# --------------------------------------------------------------------- fetch

_magic() {
	head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n'
}

_record() {
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" \
		>"${STATE}/.fetch/${1}__${2}"
}

# Runs in a forked child (xargs -n 3), so it must only use exported state.
_fetch_one() {
	local _name="$1" _arch="$2" _url="$3"
	local _dir="${STATE}/cache/${_name}"
	local _out="${_dir}/${_arch}-repodata"
	local _tmp="${_out}.part"
	local _http _rc _bytes=0 _count=0 _magic _status

	mkdir -p "$_dir" "${STATE}/.fetch"

	if [ "$DO_FETCH" -eq 1 ]; then
		_http="$(curl -fsSL --retry 2 --connect-timeout 15 --max-time 300 \
			-o "$_tmp" -w '%{http_code}' "${_url}/${_arch}-repodata" 2>/dev/null)"
		_rc=$?
	else
		_http="000"
		_rc=0
	fi

	if [ "$DO_FETCH" -eq 0 ]; then
		if [ -f "$_out" ]; then
			_status="cached"
		else
			_record "$_name" "$_arch" "nocache" "-" 0 0
			return 0
		fi
	fi

	[ -f "$_tmp" ] && _bytes="$(wc -c <"$_tmp" | tr -d ' ')"

	# HTTP 200 does not mean repodata. A 404 and an HTML error page are
	# both reachable, and repo.sys109.de even serves an HTML document with
	# a 200, so every fetch is classified on the real bytes.
	if [ "$DO_FETCH" -eq 1 ]; then
		if [ "$_rc" -ne 0 ]; then
			if [ "$_http" = "404" ]; then
				# Expected for aarch64*/x86_64-musl on official Void:
				# the official repo is glibc-only and has no aarch64.
				_status="absent"
			else
				_status="error"
			fi
			rm -f "$_tmp"
			_record "$_name" "$_arch" "$_status" "$_http" "$_bytes" 0
			return 0
		fi

		_magic="$(_magic "$_tmp")"
		case "$_magic" in
		28b52ffd|1f8b|425a68) ;;
		'') ;;
		*)
			_status="bad"
			rm -f "$_tmp"
			_record "$_name" "$_arch" "$_status" "$_http" "$_bytes" 0
			return 0
			;;
		esac

		if ! _count="$(_count_entries "$_tmp")"; then
			_status="bad"
			rm -f "$_tmp"
			_record "$_name" "$_arch" "$_status" "$_http" "$_bytes" 0
			return 0
		fi

		if [ "$_count" -gt 0 ]; then
			_status="ok"
			mv -f "$_tmp" "$_out"
		else
			_status="empty"
			mv -f "$_tmp" "$_out"
		fi
		_record "$_name" "$_arch" "$_status" "$_http" "$_bytes" "$_count"
		return 0
	fi

	# Cached path: recount from the stored archive.
	_count="$(_count_entries "$_out")" || _count=0
	_magic="$(_magic "$_out")"
	case "$_magic" in
	28b52ffd|1f8b|425a68) ;;
	'') ;;
	*)
		_record "$_name" "$_arch" "bad" "$_http" "$_bytes" 0
		return 0
		;;
	esac
	if [ "$_count" -gt 0 ]; then
		_status="cached"
	else
		_status="empty"
	fi
	_record "$_name" "$_arch" "$_status" "$_http" "$_bytes" "$_count"
}

_count_entries() {
	local _n
	_n="$(python3 "$DUMP" "$1" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
	[ -n "$_n" ] || return 1
	printf '%s' "$_n"
}

_fetch_all() {
	export STATE DUMP DO_FETCH
	export -f _fetch_one _magic _count_entries _record

	if [ ! -s "${STATE}/.jobs" ]; then
		_msg warning "no repository/arch pairs to fetch"
		return 0
	fi

	local _n
	_n="$(wc -l <"${STATE}/.jobs" | tr -d ' ')"
	_msg info "fetching $_n repository/arch pairs with $JOBS parallel jobs"

	# -n 3: name, arch, url. None of them can contain whitespace.
	# Cut to the first three fields first: .jobs rows carry five
	# (name arch url homepage archs) and xargs counts arguments, not
	# lines, so feeding it whole rows shifts every call after the first.
	# shellcheck disable=SC2016
	cut -f1,2,3 "${STATE}/.jobs" |
		xargs -P "$JOBS" -n 3 bash -c '_fetch_one "$@"' _
}

# ------------------------------------------------------------------ database

# repos.tsv: one row per (repo, arch) with the real fetch outcome.
_collect_repos_tsv() {
	local _out="${STATE}/repos.tsv"
	printf 'repo\tarch\turl\thomepage\tarchs\tstatus\thttp_code\tbytes\tpkg_count\n' >"$_out"

	local _name _arch _url _homepage _archs
	while IFS=$'\t' read -r _name _arch _url _homepage _archs; do
		local _rec="${STATE}/.fetch/${_name}__${_arch}"
		local _status="error" _http="-" _bytes=0 _count=0
		if [ -f "$_rec" ]; then
			# _record writes six fields: name arch status http bytes count.
			# Bind all six: with fewer variables bash folds every
			# remaining field into the last one, which silently made
			# _status the repo name and _count the whole tail.
			IFS=$'\t' read -r _rname _rarch _status _http _bytes _count <"$_rec"
		fi
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$_name" "$_arch" "$_url" "$_homepage" "$_archs" \
			"$_status" "$_http" "$_bytes" "$_count" >>"$_out"
	done <"${STATE}/.jobs"
}

# packages.tsv: repo, arch, then the columns from repodata-dump.py.
_collect_packages_tsv() {
	local _out="${STATE}/packages.tsv"
	printf 'repo\tarch\tpkgname\tpkgver\tarchitecture\tfilename-size\tinstalled_size\tsourcepkg\thomepage\tmaintainer\tlicense\tshort_desc\n' >"$_out"

	local _name _arch _url _homepage _archs _status _http _bytes _count
	local _archive
	while IFS=$'\t' read -r _name _arch _url _homepage _archs; do
		_archive="${STATE}/cache/${_name}/${_arch}-repodata"
		[ -f "$_archive" ] || continue
		IFS=$'\t' read -r _rname _rarch _status _http _bytes _count \
			<"${STATE}/.fetch/${_name}__${_arch}" 2>/dev/null || continue
		case "$_status" in
		ok|cached) ;;
		*) continue ;;
		esac
		python3 "$DUMP" "$_archive" 2>/dev/null | tail -n +2 |
			awk -v r="$_name" -v a="$_arch" -F'\t' '{print r"\t"a"\t"$0}' >>"$_out"
	done <"${STATE}/.jobs"
}

# --------------------------------------------------------------------- merge

# Union of index.plist entries for one arch. oco wins collisions.
_merge_one() {
	local _arch="$1"
	local _list="${STATE}/.merge/${_arch}.list"
	local _dest="${STATE}/merged/${_arch}"
	local _target="${_dest}/${_arch}-repodata"
	local _rc=0

	: >"$_list"
	local _name _arch2 _url _homepage _archs
	while IFS=$'\t' read -r _name _arch2 _url _homepage _archs; do
		[ "$_arch2" = "$_arch" ] || continue
		# The official Void repos are a COMPARISON BASELINE only. Merging
		# them in would swamp the community union: upstream current/x86_64
		# alone carries ~14.8k packages against oco's ~261. They stay in
		# repos.tsv and packages.tsv, they just never reach the merge.
		case "$_name" in
		void-*) continue ;;
		esac
		[ -f "${STATE}/cache/${_name}/${_arch}-repodata" ] || continue
		printf '%s\t%s\n' "$_name" "${STATE}/cache/${_name}/${_arch}-repodata" >>"$_list"
	done <"${STATE}/.jobs"

	if [ ! -s "$_list" ]; then
		return 0
	fi

	mkdir -p "$_dest"
	python3 - "$_arch" "$_list" "$_target" <<-'_MERGE_EOF'
		import io
		import plistlib
		import subprocess
		import sys
		import tarfile

		arch, list_path, target = sys.argv[1], sys.argv[2], sys.argv[3]

		def read_index(path):
		    with open(path, "rb") as f:
		        magic = f.read(4)
		    if magic[:4] == b"\x28\xb5\x2f\xfd":
		        raw = subprocess.check_output(["zstd", "-dc", "--", path])
		        tf = tarfile.open(fileobj=io.BytesIO(raw), mode="r:")
		    elif magic[:2] == b"\x1f\x8b":
		        tf = tarfile.open(path, mode="r:gz")
		    else:
		        tf = tarfile.open(path, mode="r:")
		    with tf:
		        for m in tf.getmembers():
		            if m.name == "index.plist" and m.isfile():
		                return plistlib.loads(tf.extractfile(m).read())
		    raise SystemExit("no index.plist in " + path)

		sources = []
		with open(list_path) as f:
		    for line in f:
		        line = line.rstrip("\n")
		        if not line:
		            continue
		        repo, path = line.split("\t", 1)
		        sources.append((repo, path))

		# oco first so its entries win every collision.
		sources.sort(key=lambda s: 0 if s[0] == "oco" else 1)

		index = {}
		owner = {}
		collisions = []
		for repo, path in sources:
		    for name, entry in read_index(path).items():
		        if name in index:
		            collisions.append((name, repo, owner[name]))
		            continue
		        index[name] = entry
		        owner[name] = repo

		# All THREE members are required. With index.plist alone,
		# xbps-query -C <confdir> -R returns rc=0 and silently empty
		# output -- a missing-member archive looks like success.
		buf = io.BytesIO()
		with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tf:
		    for member, data in (
		        ("index.plist", plistlib.dumps(index)),
		        ("index-meta.plist", b""),
		        ("stage.plist", b""),
		    ):
		        info = tarfile.TarInfo(member)
		        info.size = len(data)
		        info.mtime = 0
		        info.mode = 0o644
		        info.uid = info.gid = 0
		        info.uname = info.gname = "root"
		        tf.addfile(info, io.BytesIO(data))

		out = subprocess.run(
		    ["zstd", "-q", "-c"], input=buf.getvalue(), capture_output=True
		)
		if out.returncode != 0 or not out.stdout:
		    raise SystemExit("zstd compression failed: " + out.stderr.decode())

		with open(target + ".part", "wb") as f:
		    f.write(out.stdout)

		for name, repo, won_by in collisions:
		    print(f"collision\t{name}\t{repo}\t{won_by}", file=sys.stderr)

		print(f"{arch}\t{len(index)}\t{len(sources)}\t{len(collisions)}")
	_MERGE_EOF
	_rc=$?

	if [ "$_rc" -eq 0 ]; then
		mv -f "${_target}.part" "$_target"
	fi
	rm -f "${_target}.part"
	return "$_rc"
}

_merge_all() {
	mkdir -p "${STATE}/.merge"
	local _arch _log _n _c
	for _arch in $ARCHES; do
		_log="$(_merge_one "$_arch")" || {
			_msg error "merge failed for $_arch"
			return 1
		}
		[ -n "$_log" ] || continue
		_n="$(printf '%s' "$_log" | cut -f2)"
		_c="$(printf '%s' "$_log" | cut -f4)"
		if [ "$_c" -gt 0 ]; then
			_msg info "$_arch: $_n packages, $_c pkgname collisions resolved in favour of oco"
		else
			_msg info "$_arch: $_n packages merged"
		fi
		mkdir -p "${STATE}/repos.d"
		printf 'repository=%s\n' "${STATE}/merged/${_arch}" \
			>"${STATE}/repos.d/10-oco-merged-${_arch}.conf"
	done
	return 0
}

# ---------------------------------------------------------------- self-check

# An unsigned merged repo works fine for a local path, but only if the tar
# carries all three members. Verify by actually querying it, and never
# report success on rc alone: xbps-query returns rc=0 with empty output.
_verify_merged() {
	local _host _arch _count _pkg _expected _out _lines _rc=0

	_host="$(uname -m)"
	_arch="$_host"

	if [ ! -f "${STATE}/merged/${_arch}/${_arch}-repodata" ]; then
		_msg warn "no merged repodata for the host arch ($_arch), skipping self-check"
		return 0
	fi

	command -v xbps-query >/dev/null 2>&1 || {
		_msg warn "xbps-query not available, skipping merged repo self-check"
		return 0
	}

	_count="$(python3 "$DUMP" "${STATE}/merged/${_arch}/${_arch}-repodata" |
		tail -n +2 | wc -l | tr -d ' ')"
	[ "${_count:-0}" -gt 0 ] || {
		_msg error "merged repodata for $_arch is empty"
		return 1
	}

	_pkg="$(python3 "$DUMP" "${STATE}/merged/${_arch}/${_arch}-repodata" |
		sed -n '2p' | cut -f1)"
	_expected="$(python3 "$DUMP" "${STATE}/merged/${_arch}/${_arch}-repodata" |
		sed -n '2p' | cut -f2)"

	# -C points at our confdir so only the merged repo is consulted.
	# -i would mean the opposite: it ignores xbps.d repositories.
	_out="$(xbps-query -C "${STATE}/repos.d" -R -s -p pkgver "$_pkg" 2>&1)"
	_lines="$(printf '%s\n' "$_out" | grep -c . )"

	if [ "${_lines:-0}" -eq 0 ]; then
		_msg error "xbps-query returned no result for $_pkg from the merged repo"
		_msg error "(an unsigned local repo needs all three tar members; empty output means it was ignored)"
		_rc=1
	elif ! printf '%s' "$_out" | grep -qF "$_expected"; then
		_msg error "xbps-query resolved $_pkg to something other than $_expected:"
		printf '%s\n' "$_out" >&2
		_rc=1
	else
		_msg info "self-check ok: xbps-query -C resolved $_pkg -> $_expected from ${_count} merged packages"
	fi
	return "$_rc"
}

# -------------------------------------------------------------------- output

# rpmvercmp-style comparison. Numeric runs compare numerically, alpha runs
# lexicographically, "~" sorts before everything and "^" after, and . - _ +
# are separators. Plain `<` on version strings is wrong and is never used.
_VCMP_AWK='
function segs(s, arr,   n, t, c) {
	n = 0
	while (s != "") {
		c = substr(s, 1, 1)
		if (c ~ /[0-9]/) {
			if (match(s, /^[0-9]+/)) {
				t = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
				sub(/^0+/, "", t); if (t == "") t = "0"
				arr[++n] = "N" t
			}
		} else if (c ~ /[A-Za-z]/) {
			if (match(s, /^[A-Za-z]+/)) {
				arr[++n] = "A" substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
			}
		} else if (c == "~") {
			arr[++n] = "~"; s = substr(s, 2)
		} else if (c == "^") {
			arr[++n] = "^"; s = substr(s, 2)
		} else {
			s = substr(s, 2)
		}
	}
	return n
}
function rank(t) {
	if (t == "~") return 0
	if (t == "^") return 4
	if (substr(t, 1, 1) == "N") return 2
	if (substr(t, 1, 1) == "A") return 3
	return 1
}
function vcmp(v1, v2,   A, B, na, nb, i, x, y) {
	na = segs(v1, A); nb = segs(v2, B)
	for (i = 1; i <= na || i <= nb; i++) {
		if (i > na) { if (rank(B[i]) == 0) continue; return -1 }
		if (i > nb) { if (rank(A[i]) == 0) continue; return 1 }
		x = A[i]; y = B[i]
		if (x == y) continue
		if (rank(x) != rank(y)) return (rank(x) < rank(y)) ? -1 : 1
		if (substr(x, 1, 1) == "N") {
			# both numeric: longer string wins after zero stripping
			x = substr(x, 2); y = substr(y, 2)
			if (length(x) != length(y)) return (length(x) < length(y)) ? -1 : 1
		}
		x = substr(x, 2); y = substr(y, 2)
		return (x < y) ? -1 : 1
	}
	return 0
}
# "Name-version_revision" -> compare version, then revision numerically.
function pkgcmp(a, b,   va, ra, vb, rb, pa, pb, c) {
	pa = index(a, "-"); pb = index(b, "-")
	ra = a; rb = b
	if (pa > 0) { va = substr(a, pa + 1); ra = substr(a, 1, pa - 1) }
	if (pb > 0) { vb = substr(b, pb + 1); rb = substr(b, 1, pb - 1) }
	c = vcmp(va, vb)
	if (c != 0) return c
	# revision is the trailing _N of the version part
	sub(/.*_/, "", va); sub(/.*_/, "", vb)
	c = vcmp(va, vb)
	if (c != 0) return c
	return vcmp(ra, rb)
}
'

_build_table() {
	local _arch _tmp
	_tmp="$(mktemp)"

	printf '== %s (%s) ==\n\n' "$PROGNAME" "state: ${STATE}"

	for _arch in $ARCHES; do
		printf '%s\n' "--- $_arch ---"
		awk -F'\t' -v arch="$_arch" "$_VCMP_AWK"'
		BEGIN { FS = "\t" }
		NR == FNR {
			if (FNR > 1 && $2 == arch && $1 == "oco") oco[$3] = $4
			next
		}
		{
			if ($2 != arch) next
			r = $1
			total[r]++
			if (!($3 in oco)) { neu[r]++; next }
			c = pkgcmp($4, oco[$3])
			if (c > 0) newer[r]++
			else if (c < 0) older[r]++
			else same[r]++
		}
		END {
			for (r in total)
				printf "%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\n", r, "", "", "", total[r], neu[r]+0, newer[r]+0, older[r]+0, same[r]+0
		}' "${STATE}/packages.tsv" "${STATE}/packages.tsv" >"$_tmp"

		if [ ! -s "$_tmp" ]; then
			printf '(no package data for %s)\n' "$_arch"
			continue
		fi

		{
			printf 'repo\tstatus\thttp\tbytes\tpkgs\tnew\tnewer\tolder\tsame\n'
			# Merge in the fetch outcome from repos.tsv.
			awk -F'\t' -v arch="$_arch" '
				BEGIN { FS = "\t" }
				NR == FNR {
					if (FNR > 1 && $2 == arch) st[$1] = $6 " " $7 " " $8
					next
				}
				{
					split(st[$1], p, " ")
					printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, p[1], p[2], p[3], $5, $6, $7, $8, $9
				}' "${STATE}/repos.tsv" "$_tmp" |
				sort -t"$(printf '\t')" -k1,1
		} | column -t -s"$(printf '\t')"
		rm -f "$_tmp"
	done

	printf '\nLegend: new = not in oco, newer/older/same = compared to the oco pkgver\n'
}

_write_repos_d_note() {
	cat >"${STATE}/repos.d/README.md" <<-EOF
		# Merged community repodata

		Query it with:

		    xbps-query -C ${STATE}/repos.d -R -s -p pkgver <pkgname>

		Do **not** use \`-i\`: that flag means "ignore repositories defined
		in xbps.d", which discards exactly the repositories here.

		These archives are unsigned and live in a scratch directory. They
		are a comparison artifact, never something to upload to
		repo.osowoso.org.
	EOF
}

_write_json() {
	python3 - "${STATE}" "$ARCHES" "${STATE}/reports/compare-$(date -u +%Y%m%dT%H%M%SZ).json" <<-'_JSON_EOF'
		import json
		import os
		import subprocess
		import sys

		state, arches, out_path = sys.argv[1], sys.argv[2].split(), sys.argv[3]
		dump = os.path.join(os.environ.get("REPO_ROOT", "."), "src", "repodata-dump.py")

		repos = []
		with open(os.path.join(state, "repos.tsv")) as f:
		    header = f.readline().rstrip("\n").split("\t")
		    for line in f:
		        cols = line.rstrip("\n").split("\t")
		        row = dict(zip(header, cols))
		        for k in ("bytes", "pkg_count"):
		            try:
		                row[k] = int(row[k])
		            except (ValueError, KeyError):
		                row[k] = 0
		        repos.append(row)

		packages = []
		pkgs_path = os.path.join(state, "packages.tsv")
		with open(pkgs_path) as f:
		    header = f.readline().rstrip("\n").split("\t")
		    for line in f:
		        packages.append(dict(zip(header, line.rstrip("\n").split("\t"))))

		merged = {}
		for arch in arches:
		    path = os.path.join(state, "merged", arch, arch + "-repodata")
		    if not os.path.exists(path):
		        merged[arch] = {"present": False, "packages": 0}
		        continue
		    # index-meta.plist holds the public key as bytes, so it must
		    # never go through json.dumps directly.
		    count = 0
		    try:
		        proc = subprocess.run(
		            ["python3", dump, path], capture_output=True, text=True, check=True
		        )
		        count = max(0, len(proc.stdout.rstrip("\n").split("\n")) - 1)
		    except subprocess.CalledProcessError:
		        pass
		    merged[arch] = {
		        "present": True,
		        "path": path,
		        "packages": count,
		        "unsigned": True,
		    }

		report = {
		    "generated_at": subprocess.check_output(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"]).decode().strip(),
		    "state_dir": state,
		    "arches": arches,
		    "repository_count": len(repos),
		    "package_count": len(packages),
		    "repos": repos,
		    "merged": merged,
		    "packages": packages,
		}
		with open(out_path, "w") as f:
		    json.dump(report, f, indent=1, sort_keys=True)
		print(out_path)
	_JSON_EOF
}

_write_reports() {
	local _ts _md _html
	_ts="$(date -u +%Y%m%dT%H%M%SZ)"
	_md="${STATE}/reports/compare-${_ts}.md"
	_html="${STATE}/reports/compare-${_ts}.html"
	mkdir -p "${STATE}/reports"

	{
		printf '# Community repository comparison\n\n'
		printf -- '- generated: `%s`\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf -- '- state dir: `%s`\n' "$STATE"
		printf -- '- arches: `%s`\n\n' "$ARCHES"
		printf '## Repositories\n\n'
		_md_table_repos
		printf '\n## Packages per architecture\n\n'
		local _arch
		for _arch in $ARCHES; do
			printf '### %s\n\n' "$_arch"
			_build_table_arch_md "$_arch"
			printf '\n'
		done
	} >"$_md"

	# Self-contained HTML: inline CSS, no external assets.
	python3 - "$_md" "$_html" "$STATE" <<-'_HTML_EOF'
		import html
		import sys

		src, dest, state = sys.argv[1], sys.argv[2], sys.argv[3]
		with open(src) as f:
		    md = f.read()

		def row(cell, tag):
		    return f"<{tag}>{html.escape(cell)}</{tag}>"

		out = [
		    "<!DOCTYPE html><html lang=en><head><meta charset=utf-8>",
		    "<title>Community repository comparison</title>",
		    "<style>",
		    "body{font:14px/1.5 system-ui,sans-serif;margin:2rem auto;max-width:70rem;color:#222}",
		    "h1{font-size:1.6rem}h2{font-size:1.25rem;margin-top:2rem}h3{font-size:1.05rem}",
		    "pre{background:#f6f6f6;padding:1rem;overflow:auto;border-radius:4px}",
		    "table{border-collapse:collapse;margin:1rem 0;font-size:13px}",
		    "th,td{border:1px solid #ccc;padding:.25rem .5rem;text-align:left}",
		    "th{background:#f0f0f0}",
		    "</style></head><body>",
		    "<h1>Community repository comparison</h1>",
		    f"<pre>state dir: {html.escape(state)}</pre>",
		]
		inside = False
		rows = []
		for line in md.splitlines():
		    if line.startswith("# "):
		        continue
		    if line.startswith("### "):
		        if rows:
		            out.append("<table>" + "".join(rows) + "</table>")
		            rows = []
		        out.append("<h2>" + html.escape(line[4:]) + "</h2>")
		        inside = True
		        continue
		    if line.startswith("## "):
		        if rows:
		            out.append("<table>" + "".join(rows) + "</table>")
		            rows = []
		        out.append("<h2>" + html.escape(line[3:]) + "</h2>")
		        continue
		    if line.startswith("- "):
		        out.append("<p>" + html.escape(line) + "</p>")
		        continue
		    # Both markdown sections emit GitHub pipe tables, so the only
		    # row shape the converter accepts is "| a | b |". Anything else
		    # (including bare tabs) means the markdown and the converter have
		    # drifted apart again and the tables would vanish silently.
		    if line.startswith("|") and line.rstrip().endswith("|"):
		        cells = [c.strip() for c in line.strip().strip("|").split("|")]
		        # skip the "| --- | --- |" separator under the header
		        is_rule = bool(cells) and all(set(c) <= set("-: ") and c for c in cells)
		        if not is_rule:
		            tag = "th" if not rows else "td"
		            rows.append("<tr>" + "".join(row(c, tag) for c in cells) + "</tr>")
		    elif rows:
		        out.append("<table>" + "".join(rows) + "</table>")
		        rows = []
		if rows:
		    out.append("<table>" + "".join(rows) + "</table>")
		out.append("</body></html>")
		with open(dest, "w") as f:
		    f.write("\n".join(out))
	_HTML_EOF

	_msg info "wrote $_md"
	_msg info "wrote $_html"
}

# The Repositories table as a GitHub-flavoured pipe table. The HTML report is
# derived from this markdown, so both sections must speak the same dialect --
# emitting `column -t` space padding here produced a table-less HTML report.
_md_table_repos() {
	awk -F'\t' '
		function emit(n, rule,   i, s) {
			s = "|"
			for (i = 1; i <= n; i++) s = s " " (rule ? "---" : $i) " |"
			print s
		}
		NR == 1 { emit(NF, 0); emit(NF, 1); next }
		{ emit(NF, 0) }
	' "${STATE}/repos.tsv"
}

_table_rows_arch_md() {
	awk -F'\t' -v arch="$1" "$_VCMP_AWK"'
	BEGIN { FS = "\t" }
	NR == FNR {
		if (FNR > 1 && $2 == arch && $1 == "oco") oco[$3] = $4
		next
	}
	{
		if ($2 != arch) next
		r = $1
		total[r]++
		if (!($3 in oco)) { neu[r]++; next }
		c = pkgcmp($4, oco[$3])
		if (c > 0) newer[r]++
		else if (c < 0) older[r]++
		else same[r]++
	}
	END {
		n = asorti(total, order)
		for (i = 1; i <= n; i++) {
			r = order[i]
			printf "| %s | %d | %d | %d | %d | %d |\n", r, total[r], neu[r]+0, newer[r]+0, older[r]+0, same[r]+0
		}
	}' "${STATE}/packages.tsv" "${STATE}/packages.tsv"
}

_build_table_arch_md() {
	printf '| repo | pkgs | new | newer | older | same |\n'
	printf '| --- | ---: | ---: | ---: | ---: | ---: |\n'
	_table_rows_arch_md "$1"
}

# ---------------------------------------------------------------------- main

_init_state() {
	local _d
	for _d in "" cache merged repos.d reports .fetch .merge .tmp; do
		mkdir -p "${STATE}${_d:+/$_d}" || _die 2 "cannot create ${STATE}${_d:+/$_d}"
	done
}

_check_deps() {
	local _t
	for _t in curl python3 zstd od awk column xargs; do
		_need "$_t"
	done
	[ -f "$TEMPLATE" ] || _die 2 "registry template not found: $TEMPLATE"
	[ -f "$DUMP" ] || _die 2 "missing helper: $DUMP"
}

main() {
	_parse_args "$@"
	_check_deps
	_init_state

	_msg info "state dir: $STATE"
	_registry_build
	_msg info "registry: $(wc -l <"${STATE}/.registry" | tr -d ' ') repositories, $(wc -l <"${STATE}/.jobs" | tr -d ' ') repository/arch pairs"

	_fetch_all
	_collect_repos_tsv
	_collect_packages_tsv
	_msg info "database: $(($(wc -l <"${STATE}/packages.tsv") - 1)) package rows in ${STATE}/packages.tsv"

	if ! _merge_all; then
		_rc=1
	fi

	_write_repos_d_note

	if ! _verify_merged; then
		_rc=1
	fi

	printf '\n'
	_build_table

	# Feed the exit-code decision from the recorded states.
	awk -F'\t' 'NR > 1 && ($6 == "bad" || $6 == "error" || $6 == "nocache") { n++ } END { print n + 0 }' \
		"${STATE}/repos.tsv" >"${STATE}/.refetch-status.tsv.bad" || true
	_bad="$(cat "${STATE}/.refetch-status.tsv.bad")"
	rm -f "${STATE}/.refetch-status.tsv.bad"
	if [ "${_bad:-0}" -gt 0 ]; then
		_msg error "${_bad} repository/arch pairs are bad, errored or uncached"
		_rc=1
	else
		_msg info "all repository/arch pairs are ok or absent"
	fi

	if [ "$DO_JSON" -eq 1 ]; then
		_json_path="$(_write_json)" && _msg info "wrote $_json_path"
	fi
	if [ "$DO_REPORT" -eq 1 ]; then
		_write_reports
	fi

	printf '\n'
	printf 'database:  %s/repos.tsv, %s/packages.tsv\n' "$STATE" "$STATE"
	printf 'merged:    %s/merged/<arch>/<arch>-repodata (unsigned, RAM-local scratch)\n' "$STATE"
	printf 'query it:  xbps-query -C %s/repos.d -R -s -p pkgver <pkgname>\n' "$STATE"

	exit "$_rc"
}

main "$@"