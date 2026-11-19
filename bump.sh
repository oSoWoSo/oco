#!/usr/bin/env bash

# Script to ease packaging more apps together

# Architecture selectable via --arch / XBPS_TARGET_ARCH env
_cli_arch=""
_i=0
_cli_args=("$@")
while [ "$_i" -lt "${#_cli_args[@]}" ]; do
	case "${_cli_args[$_i]}" in
	-a | --arch)
		_cli_arch="${_cli_args[$((_i + 1))]:-}"
		_i=$((_i + 2))
		continue
		;;
	--arch=*)
		_cli_arch="${_cli_args[$_i]#--arch=}"
		_i=$((_i + 1))
		continue
		;;
	esac
	_i=$((_i + 1))
done
if [ -n "$_cli_arch" ]; then
	XBPS_TARGET_ARCH="$_cli_arch"
fi
XBPS_TARGET_ARCH="${XBPS_TARGET_ARCH:-x86_64}"
case "${XBPS_TARGET_ARCH}" in
x86_64 | x86_64-musl | aarch64 | aarch64-musl) ;;
*)
	echo "Unsupported architecture: ${XBPS_TARGET_ARCH}" >&2
	echo "Supported: x86_64 x86_64-musl aarch64 aarch64-musl" >&2
	exit 2
	;;
esac
export XBPS_TARGET_ARCH
readonly XBPS_TARGET_ARCH
readonly _HOST_ARCH="$(env -u XBPS_TARGET_ARCH xbps-uhelper -C /dev/null arch 2>/dev/null || echo x86_64)"
if [ "$XBPS_TARGET_ARCH" != "$_HOST_ARCH" ]; then
	_CROSS_ARGS=(-a "$XBPS_TARGET_ARCH")
else
	_CROSS_ARGS=()
fi
readonly XBPS_DISTDIR="${XBPS_DISTDIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
sourceDir="${sourceDir:-$XBPS_DISTDIR/srcpkgs}"
destinationDir="${destinationDir:-/home/z/Projekty/oco/srcpkgs}"

_as_builder() {
	if [ "$(id -u)" -eq 0 ] && command -v sudo >/dev/null 2>&1 && id builder >/dev/null 2>&1; then
		sudo -E -H builder "$@"
	else
		"$@"
	fi
}

# The bump, lint and build phases must run as the build user, never as root
export XBPS_HOSTDIR="${XBPS_HOSTDIR:-$XBPS_DISTDIR/hostdir}"

_as_builder() {
	if [ "$(id -u)" -eq 0 ] && command -v sudo >/dev/null 2>&1 && id builder >/dev/null 2>&1; then
		sudo -Eu builder "$@"
	else
		"$@"
	fi
}

# Track results for summary
declare -a SUCCEEDED=()
declare -a FAILED=()
declare -a SKIPPED=()

_g() {
	if command -v gum &>/dev/null; then
		gum style --border rounded --border-foreground "#14a113" --padding "0 1" "$@"
	else
		echo "[OK] $*"
	fi
}
_y() {
	if command -v gum &>/dev/null; then
		gum style --border rounded --border-foreground "#fdde13" --padding "0 1" "$@"
	else
		echo "[WARN] $*"
	fi
}
_r() {
	if command -v gum &>/dev/null; then
		gum style --border rounded --border-foreground "#e50203" --padding "0 1" "$@"
	else
		echo "[ERROR] $*"
	fi
}

_summary() {
	echo ""
	echo "=========================================="
	echo "SUMMARY"
	echo "=========================================="
	if ((${#SUCCEEDED[@]})); then
		_g "Succeeded: ${#SUCCEEDED[@]}"
		printf '  - %s\n' "${SUCCEEDED[@]}"
	fi
	if ((${#FAILED[@]})); then
		_r "Failed: ${#FAILED[@]}"
		printf '  - %s\n' "${FAILED[@]}"
	fi
	if ((${#SKIPPED[@]})); then
		_y "Skipped: ${#SKIPPED[@]}"
		printf '  - %s\n' "${SKIPPED[@]}"
	fi
	echo "=========================================="
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		{
			echo ""
			echo "=========================================="
			echo "SUMMARY"
			echo "=========================================="
			if ((${#SUCCEEDED[@]})); then
				echo "Succeeded: ${#SUCCEEDED[@]}"
				printf '  - %s\n' "${SUCCEEDED[@]}"
			fi
			if ((${#FAILED[@]})); then
				echo "Failed: ${#FAILED[@]}"
				printf '  - %s\n' "${FAILED[@]}"
			fi
			if ((${#SKIPPED[@]})); then
				echo "Skipped: ${#SKIPPED[@]}"
				printf '  - %s\n' "${SKIPPED[@]}"
			fi
			echo "=========================================="
		} >>"$GITHUB_STEP_SUMMARY"
	fi
}

cd "$XBPS_DISTDIR" || _r "XBPS_DISTDIR not exist!"

_build_one() {
	local package="$1"
	local soname soName soOLD soNEW so output
	local failed=0
	_y "Building $package"
	output=$(mktemp) || {
		_r "Error creating temporary file"
		FAILED+=("$package")
		return 1
	}
	if ! (
		# Ensure masterdir (possibly root-owned after bump/binary-bootstrap) is
		# writable by the build user before invoking xbps-src.
		if [ "$(id -u)" -eq 0 ] && id builder >/dev/null 2>&1; then
			chown -R builder:builder "$XBPS_MASTERDIR" 2>/dev/null || true
		fi
		set -o pipefail
		_xbps=(./xbps-src "${_CROSS_ARGS[@]}" pkg -Q "$package")
		if [ "$(id -u)" -eq 0 ] && command -v sudo >/dev/null 2>&1 && id builder >/dev/null 2>&1; then
			_xbps=(sudo -Eu builder "${_xbps[@]}")
		fi
		"${_xbps[@]}" 2>&1 | tee "$output"
	); then
		_r "Error building $package"
		rm -f "$output"
		FAILED+=("$package")
		return 1
	fi
	if grep -q 'SONAME bump detected' "$output"; then
		soname=$(grep 'SONAME bump detected' "$output" | cut -d':' -f2,4)
		soName=$(echo "$soname" | cut -d' ' -f2 | cut -d':' -f1)
		soOLD=$(echo "$soname" | cut -d' ' -f3)
		soNEW=$(echo "$soname" | cut -d' ' -f5)
		echo "package name: $soName"
		echo "OLD so: $soOLD"
		echo "NEW so: $soNEW"
		if grep -q "$soOLD" common/shlibs; then
			sed -i "s|^.*${soOLD}.*$|${soNEW} ${soName}|" common/shlibs
			echo "Updated shlibs entry for $package"
		fi
	elif grep -q 'SONAME ' "$output"; then
		soname=$(grep 'SONAME ' "$output" | head -n1)
		so=$(echo "$soname" | cut -d' ' -f2)
		soName=$(echo "$soname" | cut -d' ' -f4 | rev | cut -d'/' -f1 | rev)
		echo "package name: $soName"
		echo "SO name: $so"
		if grep -q "$package" common/shlibs; then
			sed -i "s|^.*${so}.*$|${soName} ${so}|" common/shlibs
			echo "Updated shlibs entry for $package"
		fi
	fi
	rm -f "$output"
	_g "$package built successfully"
	SUCCEEDED+=("$package")
	return 0
}

# Bump a single template through the shared autobump pipeline
# (autobump-batch.py plan/apply + bump-template.sh / bump-revision.sh).
# Conservative fallback: when the batch machinery is unavailable, leave it
# to the caller's legacy xxautobump loop.
_bump_single() {
	local pkg="$1" batch root plan
	if command -v python3 >/dev/null 2>&1; then
		batch="$XBPS_DISTDIR/tools/autobump/autobump-batch.py"
		[[ -f "$batch" ]] || return 1
	else
		return 1
	fi
	# Operate on the repository holding $sourceDir (the void checkout when
	# sourceDir points at its srcpkgs/, otherwise the OCO checkout).
	if [[ "$sourceDir" == */srcpkgs && -f "${sourceDir%/srcpkgs}/xbps-src" ]]; then
		root="${sourceDir%/srcpkgs}"
	else
		root="$XBPS_DISTDIR"
	fi
	if [[ ! -f "$root/config/autobump-packs.tsv" && -f "$(dirname "$root")/config/autobump-packs.tsv" ]]; then
		root="$(dirname "$root")"
	fi
	if [[ -L "$sourceDir/$pkg" ]]; then
		_y "$pkg is a symlink; skipping bump"
		SKIPPED+=("$pkg (symlink)")
		return 0
	fi
	if [[ -f "$sourceDir/$pkg/template" ]] && ! grep -qE '^[[:space:]]*distfiles=' "$sourceDir/$pkg/template"; then
		_y "$pkg has no distfiles; treating as metapackage"
		SKIPPED+=("$pkg (metapackage)")
		return 0
	fi
	echo -e "\n================================"
	echo "📦 Processing: $pkg"
	echo "================================"
	plan=$(mktemp) || {
		_r "Error creating temporary file"
		FAILED+=("$pkg")
		return 1
	}
	local xbps_arg=()
	if [[ -n "${XBPS_SRC:-}" ]]; then
		xbps_arg=(--xbps-src "$XBPS_SRC")
	elif [[ -x "$root/xbps-src" ]]; then
		xbps_arg=(--xbps-src "$root/xbps-src")
	fi
	if ! python3 "$batch" plan "$pkg" --output "$plan" --repo-root "$root" "${xbps_arg[@]}" 2>"$plan.err"; then
		_r "Error planning $pkg"
		cat "$plan.err" >&2
		rm -f "$plan" "$plan.err"
		FAILED+=("$pkg (plan)")
		return 0
	fi
	rm -f "$plan.err"
	if [[ ! -s "$plan" ]]; then
		_y "No updated version found for $pkg"
		SKIPPED+=("$pkg (bump)")
		rm -f "$plan"
		return 0
	fi
	if ! python3 "$batch" apply --plan "$plan" --repo-root "$root" 2>"$plan.err"; then
		_r "Error bumping $pkg"
		cat "$plan.err" >&2
		rm -f "$plan" "$plan.err"
		FAILED+=("$pkg (apply)")
		return 0
	fi
	rm -f "$plan.err"
	local failed=0
	while IFS=$'\t' read -r package version kind _order; do
		[[ -n "$package" ]] || continue
		if [[ "$kind" == version ]]; then
			_g "$package bumped to $version"
			SUCCEEDED+=("$package (bumped to $version)")
			if [[ "$build" = 1 ]]; then
				if _build_one "$package"; then
					if git add . && git commit -m "$package: update to $version"; then
						_g "$package committed successfully"
					else
						_r "Error committing $package"
						FAILED+=("$package (commit)")
						failed=$((failed + 1))
					fi
				else
					_r "Error building $package"
					FAILED+=("$package (build)")
					failed=$((failed + 1))
				fi
			fi
		else
			_g "$package: raised revision for updated dependencies"
			SUCCEEDED+=("$package (revision bump)")
		fi
	done <"$plan"
	rm -f "$plan"
	if ((failed)); then
		_r "Bumping done with $failed error(s)"
		return 1
	fi
	_g "Bumping done"
	return 0
}

_bump() {
	local package revdeps dep new output failed=0
	local -A _bumped=()
	if ((${#packageList[@]} == 1)); then
		if _bump_single "${packageList[0]}"; then
			return 0
		fi
		_y "Falling back to xxautobump for ${packageList[0]}"
	fi
	for package in "${packageList[@]}"; do
		if [[ -L "$sourceDir/$package" ]]; then
			_y "$package is a symlink; skipping bump"
			SKIPPED+=("$package (symlink)")
			continue
		fi
		if [[ -f "$sourceDir/$package/template" ]] && ! grep -qE '^[[:space:]]*distfiles=' "$sourceDir/$package/template"; then
			_y "$package has no distfiles; treating as metapackage"
			SKIPPED+=("$package (metapackage)")
			_bumped[$package]=1
			continue
		fi
		if [[ -n "${_bumped[$package]:-}" ]]; then
			_y "$package already bumped this run; skipping"
			SKIPPED+=("$package (already bumped)")
			continue
		fi
		new=''
		output=$(mktemp) || {
			_r "Error creating temporary file"
			FAILED+=("$package")
			return 1
		}
		echo -e "\n================================"
		echo "📦 Processing: $package"
		echo "================================"
		echo "Finding reverse dependencies..."
		revdeps=$(xrevshlib "$package" 2>/dev/null | awk '{print $1}' | sort -u)
		if [[ -n "$revdeps" ]]; then
			echo "Reverse dependencies found:"
			while IFS= read -r dep; do
				echo "  - $dep"
			done <<<"$revdeps"
		else
			echo "No reverse dependencies found"
		fi
		_bumped[$package]=1
		echo "Bumping $package..."
		# Reinforce environment and ownership so xbps-src (invoked by xxautobump)
		# never falls back to a non-writable masterdir.
		export XBPS_MASTERDIR="${XBPS_MASTERDIR:-${XBPS_DISTDIR}/masterdir_${group}}"
		export XBPS_DISTDIR
		if [ "$(id -u)" -eq 0 ] && id builder >/dev/null 2>&1; then
			mkdir -p "$XBPS_MASTERDIR"
			chown -R builder:builder "$XBPS_MASTERDIR" 2>/dev/null || true
		fi
		if (
			set -o pipefail
			xxautobump "$package" 2>&1 | tee "$output"
		); then
			new=$(awk '/Updating package/ {print $(NF-1)}' "$output")
			if [[ -n "$new" ]]; then
				_g "$package bumped to $new"
				SUCCEEDED+=("$package (bumped to $new)")
				if [[ "$build" = 1 ]]; then
					if _build_one "$package"; then
						if git add . &&
							git commit -m "$package: update to $new"; then
							_g "$package committed successfully"
						else
							_r "Error committing $package"
							FAILED+=("$package (commit)")
							failed=$((failed + 1))
						fi
					else
						_r "Error building $package"
						FAILED+=("$package (build)")
						failed=$((failed + 1))
					fi
				fi
			else
				_y "No updated version found for $package"
				SKIPPED+=("$package (bump)")
			fi
			rm -f "$output"
		else
			_r "Error bumping $package"
			cat "$output"
			rm -f "$output"
			FAILED+=("$package")
			failed=$((failed + 1))
			continue
		fi
		if [[ -n "$revdeps" && -n "$new" ]]; then
			echo "Bumping reverse dependencies..."
			while IFS= read -r dep; do
				[[ -z "$dep" ]] && continue
				echo "  Bumping $dep..."
				if xrevbump "revbump for $package" "$dep" "version"; then
					_bumped[$dep]=1
					_g "$dep: rebuild for $package update"
				else
					_r "Error bumping $dep"
					FAILED+=("$dep (revbump)")
					failed=$((failed + 1))
				fi
			done <<<"$revdeps"
		fi
	done
	if ((failed)); then
		_r "Bumping done with $failed error(s)"
		return 1
	fi
	_g "Bumping done"
}

_lint() {
	local failed=0
	for package in "${packageList[@]}"; do
		if xlint "$package"; then
			_g "$package linted successfully"
			SUCCEEDED+=("$package (lint)")
		else
			_r "Lint error: $package"
			FAILED+=("$package (lint)")
			((failed++))
		fi
	done
	if ((failed)); then
		_r "Linting done: $failed package(s) failed"
		return 1
	fi
	_g "Linting done: all packages passed"
}

_build() {
	local _build_marker
	_build_marker=$(mktemp) || {
		_r "Error creating temporary file"
		return 1
	}
	touch "$_build_marker"
	rm -f "build-${group}"
	if [[ "${recordOrder:-0}" = 1 || "${RECORD_BUILD_ORDER:-0}" = 1 ]]; then
		: >"build-${group}.order"
	fi
	for package in "${packageList[@]}"; do
		_y "Building $package"
		if (
			if [ "$(id -u)" -eq 0 ] && id builder >/dev/null 2>&1; then
				chown -R builder:builder "$XBPS_MASTERDIR" 2>/dev/null || true
			fi
			set -o pipefail
			_xbps=(./xbps-src "${_CROSS_ARGS[@]}" pkg -Q "$package")
			if [ "$(id -u)" -eq 0 ] && command -v sudo >/dev/null 2>&1 && id builder >/dev/null 2>&1; then
				_xbps=(sudo -Eu builder "${_xbps[@]}")
			fi
			"${_xbps[@]}" 2>&1 | tee -a "build-${group}.log"
		); then
			_g "$package built successfully"
			SUCCEEDED+=("$package (build)")
			if [[ "${recordOrder:-0}" = 1 || "${RECORD_BUILD_ORDER:-0}" = 1 ]]; then
				printf '%s\n' "$package" >>"build-${group}.order"
			fi
		else
			_r "Error building $package"
			FAILED+=("$package (build)")
			#exit 1
			_print_built_packages "$_build_marker"
			rm -f "$_build_marker"
			return 1
		fi
	done
	_print_built_packages "$_build_marker"
	rm -f "$_build_marker"
	_g "Building done"
}

_print_built_packages() {
	local marker="$1"
	echo ""
	_y "Built packages (sorted by creation time):"
	find hostdir/binpkgs -type f -name '*.xbps' -newer "$marker" -printf '%T@ %f\n' 2>/dev/null | sort -n | sed 's/^[0-9.]* //'
}

_install() {
	_y "Installing Hyprland"
	local failed=0
	for package in "${packageList[@]}"; do
		_y "Installing $package"
		if xi -f "$package"; then
			_g "$package installed successfully"
			SUCCEEDED+=("$package (install)")
		else
			_r "Error installing $package"
			FAILED+=("$package (install)")
			failed=$((failed + 1))
		fi
	done
	if ((failed)); then
		_r "Installation completed with $failed error(s)"
		return 1
	fi
	_g "Installation completed"
}

# Subpackages of $1 are discovered, never hardcoded:
#   - <sub>_package() functions declared in the template (authoritative)
#   - symlinks in $sourceDir pointing at $1 (catches subpackages whose
#     _package() function was dropped but whose symlink still exists)
# Printed as "<name> <parent>", deduplicated.
declare -A _linksByTarget=()

_collect_links() {
	local link name target
	_linksByTarget=()
	while IFS= read -r link; do
		[[ -z "$link" ]] && continue
		name=${link##*/}
		target=$(readlink "$link") || continue
		target=${target#./}
		[[ -z "$target" ]] && continue
		_linksByTarget[$target]="${_linksByTarget[$target]:-} $name"
	done < <(find "$sourceDir" -maxdepth 1 -type l 2>/dev/null)
}

_subpackages() {
	local pkg="$1" name
	if [[ -f "$sourceDir/$pkg/template" ]]; then
		while IFS= read -r name; do
			[[ -n "$name" && "$name" != "$pkg" ]] && printf '%s %s\n' "$name" "$pkg"
		done < <(
			grep -oE '^[[:alnum:]][[:alnum:]_+.-]*_package\(\)' "$sourceDir/$pkg/template" 2>/dev/null |
				sed 's/_package()$//'
		)
	fi
	for name in ${_linksByTarget[$pkg]:-}; do
		printf '%s %s\n' "$name" "$pkg"
	done
}

# Every <sub>_package() needs a srcpkgs/<sub> symlink to <parent>, otherwise
# xbps-src never builds the subpackage. Create it even when sourceDir lacks it.
_copy_symlink() {
	local entry="$1" parent="$2" target="${3:-}"
	[[ -n "$target" ]] || target="$parent"
	if [[ ! -d "$destinationDir/$parent" ]]; then
		_r "Error creating symlink $entry: parent $parent not copied"
		FAILED+=("$entry (copy symlink)")
		return 1
	fi
	_y "Copying $entry symlink ($target)"
	if ! rm -f "$destinationDir/$entry" ||
		! ln -s "$target" "$destinationDir/$entry"; then
		_r "Error copying symlink $entry"
		FAILED+=("$entry (copy symlink)")
		return 1
	fi
	_g "$entry symlink copied successfully"
	SUCCEEDED+=("$entry (copy symlink)")
	return 0
}

_copy_one() {
	local entry="$1" parent="$2" target="${3:-}"
	if [[ -n "$parent" ]]; then
		if [[ -L "$sourceDir/$entry" ]]; then
			target=$(readlink "$sourceDir/$entry")
			target=${target#./}
		fi
		_copy_symlink "$entry" "$parent" "$target"
		return $?
	fi
	if [[ -L "$sourceDir/$entry" ]]; then
		_copy_symlink "$entry" "$(readlink "$sourceDir/$entry")" "$(readlink "$sourceDir/$entry")"
		return $?
	fi
	_y "Removing and copying newer $entry template"
	if ! rm -rf "$destinationDir/$entry"; then
		_r "Error removing $entry"
		FAILED+=("$entry (copy)")
		return 1
	fi
	if ! cp -r "$sourceDir/$entry" "$destinationDir/"; then
		_r "Error copying $entry"
		FAILED+=("$entry (copy)")
		return 1
	fi
	_g "$entry copied successfully"
	SUCCEEDED+=("$entry (copy)")
	return 0
}

# Sync common/shlibs entries for a package into oco/shlibs_append.
# For each SONAME line in source common/shlibs whose package field belongs
# to $1, update the matching (soname + same package) line in shlibs_append
# or append it if missing. Duplicate exact lines are never created.
_sync_shlibs() {
	local pkg="$1"
	local srcShlibs="$XBPS_DISTDIR/common/shlibs"
	local destAppend="${destinationDir%/*}/shlibs_append"
	[[ -f "$srcShlibs" ]] || return 0
	local -A seen=()
	local -a srcLines=()
	local line sname pname
	while IFS= read -r line; do
		[[ -z "$line" || "$line" == \#* ]] && continue
		read -r sname pname _ <<<"$line"
		[[ -z "$sname" || -z "$pname" ]] && continue
		if [[ "$pname" == "$pkg"-* ]]; then
			if [[ -z "${seen[$line]:-}" ]]; then
				seen[$line]=1
				srcLines+=("$line")
			fi
		fi
	done <"$srcShlibs"
	((${#srcLines[@]} == 0)) && return 0
	[[ -f "$destAppend" ]] || : >"$destAppend"
	local tmp l ss pn tmp2 existing es ep
	tmp=$(mktemp) || return 1
	cp "$destAppend" "$tmp"
	for l in "${srcLines[@]}"; do
		read -r ss pn _ <<<"$l"
		tmp2=$(mktemp) || {
			rm -f "$tmp"
			return 1
		}
		while IFS= read -r existing; do
			[[ -z "$existing" ]] && {
				printf '%s\n' "$existing" >>"$tmp2"
				continue
			}
			read -r es ep _ <<<"$existing"
			if [[ "$es" == "$ss" && "$ep" == "$pkg"-* ]]; then
				continue
			fi
			printf '%s\n' "$existing" >>"$tmp2"
		done <"$tmp"
		if ! grep -Fxq -- "$l" "$tmp2"; then
			printf '%s\n' "$l" >>"$tmp2"
		fi
		mv "$tmp2" "$tmp"
	done
	mv "$tmp" "$destAppend"
	_g "shlibs synced for $pkg (${#srcLines[@]} line(s))"
	return 0
}

_copy() {
	local failed=0 dir sub parent
	local -A copied=()
	_collect_links
	for dir in "${packageList[@]}"; do
		copied[$dir]=1
	done
	for dir in "${packageList[@]}"; do
		_copy_one "$dir" || failed=$((failed + 1))
		_sync_shlibs "$dir" || true
		while read -r sub parent; do
			[[ -z "$sub" || -n "${copied[$sub]:-}" ]] && continue
			copied[$sub]=1
			_copy_one "$sub" "$parent" || failed=$((failed + 1))
			_sync_shlibs "$sub" || true
		done < <(_subpackages "$dir" | sort -u)
	done
	if ((failed)); then
		_r "Copying done with $failed error(s)"
		return 1
	fi
	_g "Copying done"
}

_adopt() {
	local destRoot="${destinationDir%/*}"
	_copy || return 1
	if [[ -d "$destRoot/.git" ]]; then
		git -C "$destRoot" add -A
		git -C "$destRoot" commit -m "Adopt group $group" || true
	fi
	_g "Adopted group $group"
}

_orphan() {
	local destRoot="${destinationDir%/*}" package
	for package in "${packageList[@]}"; do
		rm -rf "$destinationDir/$package"
	done
	if [[ -d "$destRoot/.git" ]]; then
		git -C "$destRoot" add -A
		git -C "$destRoot" commit -m "Orphan group $group" || true
	fi
	_g "Orphaned group $group"
}

_show_order() {
	echo "Build order for $group:"
	local i=1
	for package in "${packageList[@]}"; do
		echo "  $i. $package"
		((i++))
	done
}

_help() {
	if command -v gum &>/dev/null; then
		gum style --border rounded --border-foreground "#14a113" --padding "2 5 2 2" "
		$(gum style --foreground '#14a113' 'Script to help with group packaging')

		Possible arguments are:
		u OR --bump     Bump all group packages, or a single template
		l OR --lint     Lint all group packages, or a single template
		b OR --build    Build all group packages
		c OR --copy     Copy templates + their subpackages (symlinks)
		i OR --install  Install all group packages
		o OR --order    Show build order only
		h OR --help     Show this help message
		a OR --all      bump, build, copy and install
		--arch <arch>   Target architecture (x86_64, x86_64-musl, aarch64, aarch64-musl)

		$(gum style --foreground '#14a113' 'You must take care of Shlibs yourself!')
		To set sourceDir and destinationDir yourself
		Just export them before running script

		shlibs Must be handled manually for now!"
	else
		cat <<'HELP'
Script to help with group packaging

Possible arguments are:
  u OR --bump     Bump all group packages, or a single template
  l OR --lint     Lint all group packages, or a single template
  b OR --build    Build all group packages
  c OR --copy     Copy templates + their subpackages (symlinks)
  i OR --install  Install all group packages
  o OR --order    Show build order only
  adopt OR --adopt   Adopt group templates into destination
  orphan OR --orphan  Remove group templates from destination
  r OR --record-order  Record successful build order to build-<group>.order
  h OR --help     Show this help message
  a OR --all      bump, build, copy and install
  --arch <arch>   Target architecture (x86_64, x86_64-musl, aarch64, aarch64-musl)

Multiple actions can be combined in one invocation, e.g.:
  ./bump.sh <group> bump lint build order

You must take care of Shlibs yourself outside of copy!
To set sourceDir and destinationDir yourself
Just export them before running script

Shlibs are synced automatically during copy (common/shlibs -> oco/shlibs_append).
HELP
	fi
}

# Groups are defined declaratively in config/autobump-packs.tsv (single source of truth).
_groups_file() {
	echo "${groupsFile:-$(dirname "$destinationDir")/config/autobump-packs.tsv}"
}

show_packs() {
	local gf
	gf="$(_groups_file)"
	[[ -f "$gf" ]] || return 0
	awk -F'\t' '!/^#/ && NF>=2 {print $1}' "$gf" | sort -u
}

case "${1:-}" in
-h | --help)
	_help
	exit 0
	;;
esac

if [ -z "$1" ]; then
	echo 'Pick a group or a single template as first argument:'
	show_packs
	echo 'Then pick second argument'
	_help
	exit 1
fi

gf="$(_groups_file)"
declare -a packageList=()
group=''
if show_packs | grep -qx -- "$1"; then
	# $1 is a declared group name: resolve it to its package list.
	group="$1"
	gf="$(_groups_file)"
	if [[ ! -f "$gf" ]]; then
		_r "Groups file not found: $gf"
		exit 1
	fi
	mapfile -t packageList < <(awk -F'\t' -v g="$group" '
		$1==g && !/^#/ {
			pkg=$2
			sub(/#.*/, "", pkg)
			gsub(/^[ \t]+|[ \t]+$/, "", pkg)
			if (pkg != "") print pkg
		}
	' "$gf")
	if ((${#packageList[@]} == 0)); then
		_r "No packages found for group '$group' in $gf"
		exit 1
	fi
	shift
else
	# $1 is not a group, so treat it as a single template.
	template="$1"
	if [[ ! -d "$sourceDir/$template" ]]; then
		echo "Unknown group or template: $template"
		echo 'Pick a group or a single template as first argument:'
		show_packs
		exit 1
	fi
	group="$template"
	packageList=("$template")
	shift
fi

if [ $# -eq 0 ]; then
	echo 'Provide at least one action argument!'
	_help
	exit 1
fi

# Use own masterdir per group
export XBPS_MASTERDIR="${XBPS_DISTDIR}/masterdir_${group}"

# Ensure the masterdir is writable by the build user (CI runs as root).
if [ "$(id -u)" -eq 0 ] && id builder >/dev/null 2>&1; then
	mkdir -p "$XBPS_MASTERDIR"
	chown -R builder:builder "$XBPS_MASTERDIR"
fi

# Ensure the sources directory (bind-mounted as /host/sources inside the chroot)
# exists and is writable by the build user, otherwise do-fetch fails with
# "mkdir: cannot create directory ... Permission denied".
mkdir -p "${XBPS_MASTERDIR}/host/sources"
if id builder >/dev/null 2>&1; then
	chown -R builder:builder "${XBPS_MASTERDIR}/host/sources"
else
	chown -R "$(id -u):$(id -g)" "${XBPS_MASTERDIR}/host/sources"
fi

# Allow combining multiple actions, e.g.:
#   ./bump.sh <group> bump lint build order
# Global flags are collected in a first pass so they apply to every action
# regardless of argument order.
build=0
recordOrder=0
declare -a _actions=()
_i=0
_args=("$@")
while [ "$_i" -lt "${#_args[@]}" ]; do
	_arg="${_args[$_i]}"
	case "$_arg" in
	-a | --arch)
		_i=$((_i + 2))
		continue
		;;
	--arch=*)
		_i=$((_i + 1))
		continue
		;;
	l | --lint) _actions+=("lint") ;;
	b | --build)
		_actions+=("build")
		build=1
		;;
	o | --order) _actions+=("order") ;;
	r | --record-order)
		_actions+=("record")
		recordOrder=1
		;;
	u | --bump) _actions+=("bump") ;;
	i | --install) _actions+=("install") ;;
	c | --copy) _actions+=("copy") ;;
	adopt | --adopt) _actions+=("adopt") ;;
	orphan | --orphan) _actions+=("orphan") ;;
	a | --all)
		_actions+=("all")
		build=1
		;;
	h | --help)
		_help
		exit 0
		;;
	*)
		echo "Unknown argument: $_arg"
		_help
		exit 1
		;;
	esac
	_i=$((_i + 1))
done

for _action in "${_actions[@]}"; do
	case "$_action" in
	lint) _lint ;;
	build) _build ;;
	order) _show_order ;;
	record) : ;;
	bump) _bump ;;
	install) _install ;;
	copy) _copy ;;
	adopt) _adopt ;;
	orphan) _orphan ;;
	all)
		build=1
		_lint
		_bump
		_install
		_copy
		_g "Everything done"
		;;
	esac
done

_summary

if ((${#FAILED[@]})); then
	exit 1
fi
