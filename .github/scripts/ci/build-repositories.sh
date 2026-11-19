#!/usr/bin/env bash
# Select binary dependencies for xbps-src, not repositories for the CI host.
# The builder image already supplies production repositories and signing keys.
set -euo pipefail

channel=${BUILD_REPOSITORY_CHANNEL:-production}
case "$channel" in
  production|testing) ;;
  *) echo "::error::Unsupported build repository channel: $channel"; exit 1 ;;
esac

config_dir="${XBPS_DISTDIR:-/void-packages}/etc/xbps.d"
[[ -d "$config_dir" ]] || { echo "::error::Missing xbps-src repository configuration: $config_dir"; exit 1; }
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# xbps-src selects the bootstrap/target architecture's config independently.
# Cover generic glibc/musl and per-architecture overrides, but not multilib:
# the testing repository has no separate multilib channel.
for spec in \
  repos-remote.conf:x86_64 \
  repos-remote-musl.conf:x86_64-musl \
  repos-remote-x86_64.conf:x86_64 \
  repos-remote-x86_64-musl.conf:x86_64-musl \
  repos-remote-aarch64.conf:aarch64 \
  repos-remote-aarch64-musl.conf:aarch64-musl; do
  file="$config_dir/${spec%%:*}"
  arch=${spec#*:}
  [[ -f "$file" ]] || continue
  repository="repository=https://repo.osowoso.org/testing/$arch"
  # Idempotent, including when switching back to production. Keep the original
  # production/Void entries and their relative order, ownership and permissions.
  awk -v repository="$repository" '$0 != repository' "$file" > "$tmp"
  {
    if [[ "$channel" == testing ]]; then
      printf '%s\n' "$repository"
    fi
    cat "$tmp"
  } > "$file"
  echo "==> $channel build dependencies: ${file##*/} ($arch)"
done
