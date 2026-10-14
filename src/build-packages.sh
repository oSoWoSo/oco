#!/bin/sh
# Shared build loop used by both test-pr and build CI jobs.
# Required env: PACKAGES, ARCH, BOOTSTRAP, TEST, NATIVE, FORCE
# Writes built=true/false to GITHUB_OUTPUT when that variable is set.
# When RESULT_FILE is set, records source-template results and actual XBPS
# outputs so the update feed and issue closer see binary subpackages too.
. "${GITHUB_WORKSPACE}/extra/src/pkg-helpers.sh"
export PATH="/opt/xbps/usr/bin/:$PATH"

if [ -n "${RESULT_FILE:-}" ]; then
	mkdir -p "$(dirname "$RESULT_FILE")"
	: > "$RESULT_FILE"
fi

cd /void-packages

xbps_test=''
[ "$TEST" = 1 ] && xbps_test='-Q'

force_flag=''
[ "$FORCE" = 'true' ] && force_flag='-N'

echo "==> Resolving dependencies for: $PACKAGES"
PKGS=""
_retry=0
while [ -z "$PKGS" ] && [ "$_retry" -lt 3 ]; do
	_retry=$((_retry + 1))
	echo "==> sort-dependencies attempt $_retry/3"
	PKGS=$(sudo -Eu builder ./xbps-src $xbps_test sort-dependencies $PACKAGES 2>/dev/null) || PKGS=""
	[ -z "$PKGS" ] && sleep 5
done
if [ -z "$PKGS" ]; then
	echo "==> ERROR: sort-dependencies failed after 3 attempts"
	exit 1
fi

echo "==> Build order with dependencies:"
echo "$PKGS"
echo

BUILT=false
FAILED=false
for pkg in $PKGS; do
	_ver=$(grep '^version=' "srcpkgs/$pkg/template" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' | tr -d ' ')
	if ! pkg_arch_ok "$pkg" "$ARCH"; then
		echo "==> Skipping ${pkg}: not available for ${ARCH}"
		[ -n "${RESULT_FILE:-}" ] && printf '%s\t%s\tskip\n' "$pkg" "$_ver" >> "$RESULT_FILE"
		continue
	fi

	arch_flag=''
	if [ "$BOOTSTRAP" != "$ARCH" ]; then
		case "$BOOTSTRAP/$ARCH" in
			x86_64/x86_64-musl)
				arch_flag="-A $ARCH"
				;;
			aarch64/aarch64-musl)
				# Build musl target in the aarch64 (glibc) masterdir: run natively
				# on arm64 hardware with musl cross-toolchain (Node is unavailable
				#in a aarch64-musl rootfs, so the musl host image can't host node deps).
				arch_flag="-A aarch64 -a aarch64-musl"
				;;
			*)
				# - Avoid '-A' (amd64 runners lack qemu binfmt -> 'Exec format error').
				arch_flag="-a $ARCH"
				;;
		esac
	fi

	echo "==> Building ${pkg}"
	if sudo -Eu builder ./xbps-src -j"$(nproc)" -s $force_flag $arch_flag $xbps_test pkg "$pkg"; then
		BUILT=true
		[ -n "${RESULT_FILE:-}" ] && printf '%s\t%s\tok\n' "$pkg" "$_ver" >> "$RESULT_FILE"
	else
		FAILED=true
		[ -n "${RESULT_FILE:-}" ] && printf '%s\t%s\tfail\n' "$pkg" "$_ver" >> "$RESULT_FILE"
	fi
	echo
done

if [ -n "${RESULT_FILE:-}" ]; then
	# Python 3/plistlib and tar are available in the build image. Inspect only
	# current-architecture outputs whose filenames contain a successful source
	# version; metadata ties each binary back to its source template.
	if ! python3 "${GITHUB_WORKSPACE}/extra/src/collect-xbps-results.py" \
		--results "$RESULT_FILE" \
		--binpkgs /void-packages/hostdir/binpkgs \
		--arch "$ARCH"; then
		echo '==> ERROR: failed to collect XBPS package results'
		exit 1
	fi
fi

[ -n "${GITHUB_OUTPUT:-}" ] && printf 'built=%s\n' "$BUILT" >> "$GITHUB_OUTPUT"
if [ "$FAILED" = true ]; then
	exit 1
fi
exit 0
