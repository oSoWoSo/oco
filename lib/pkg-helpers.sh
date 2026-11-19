#!/bin/sh
# Returns 0 if pkg is compatible with target arch, 1 if excluded.
# Source this file; do not execute directly.
# Runs in a subshell so `set -f` is auto-restored on return.

# Check if a package or any of its dependencies has nocross set.
# Returns 0 if nocross found, 1 otherwise.
_check_nocross_chain() {
	local _pkg="$1"
	local _tpl="srcpkgs/${_pkg}/template"
	[ -f "$_tpl" ] || return 1
	grep -q '^nocross=' "$_tpl" 2>/dev/null && return 0
	case " ${_cnc_visited:-} " in *" $_pkg "*) return 1 ;; esac
	_cnc_visited="$_cnc_visited $_pkg"
	local _deps=""
	for _field in hostmakedepends makedepends depends; do
		_line=$(grep -m1 "^${_field}=" "$_tpl" 2>/dev/null)
		_line="${_line#*=}"
		_line="${_line#\"}"; _line="${_line%\"}"
		_line="${_line#'}"; _line="${_line%'}"
		_deps="$_deps $_line"
	done

	local _dep _dep_name
	for _dep in $_deps; do
		_dep_name="${_dep%%[><=]*}"
		[ -z "$_dep_name" ] && continue
		[ -f "srcpkgs/${_dep_name}/template" ] || continue
		_check_nocross_chain "$_dep_name" && return 0
	done

	return 1
}

pkg_arch_ok() (
	# Disable pathname expansion: we need `for _pao_pat in $_pao_archs`
	# to split on whitespace WITHOUT globbing values like `*` or `*-musl`
	# against files in the working directory.
	set -f
	_pao_pkg="$1" _pao_tgt="$2"
	_pao_tpl="srcpkgs/${_pao_pkg}/template"
	[ -f "$_pao_tpl" ] || return 0
	_pao_archs=$(grep -m1 '^archs=' "$_pao_tpl" | sed 's/^archs=//;s/"//g')
	[ -z "$_pao_archs" ] && return 0
	_pao_last=''
	for _pao_pat in $_pao_archs; do
		_pao_last="$_pao_pat"
		# Strip leading `~` (exclusion marker). The `"~"` MUST be quoted:
		# POSIX runs tilde expansion on the pattern inside ${var#PAT},
		# so an unquoted `~` becomes $HOME and strips nothing.
		# The result is unquoted inside `case` so glob patterns from
		# `archs=` (e.g. `x86_64*`, `*-musl`) still match the target.
		_pao_strip=${_pao_pat#"~"}
		case "$_pao_tgt" in
			${_pao_strip}) case "$_pao_pat" in "~"*) return 1 ;; *) return 0 ;; esac ;;
		esac
	done
	# If the list was purely exclusions (`~foo ~bar`), unmatched targets pass.
	case "$_pao_last" in ~*) return 0 ;; esac
	return 1
)

# Print package directory names, including symlinks to existing directories.
# Dangling symlinks are excluded because `[ -d ]` follows the link.
list_srcpkgs() {
	_lsp_dir=$1
	for _lsp_entry in "$_lsp_dir"/*; do
		[ -d "$_lsp_entry" ] || continue
		printf '%s\n' "${_lsp_entry##*/}"
	done | sort -f
}
