#!/usr/bin/env bash
set -euo pipefail
SHLIBS_FILE=/void-packages/common/shlibs extra/ocoman -l

echo "==> Copying templates..."
for template in extra/srcpkgs/*; do
  template_name=$(basename "$template")
  [ -L "$template" ] && continue
  rm -rf "/void-packages/srcpkgs/$template_name"
  cp -rv "$template" /void-packages/srcpkgs/
done
for template in extra/srcpkgs/*; do
  [ -L "$template" ] || continue
  template_name=$(basename "$template")
  target_name=$(readlink "$template")
  case "$target_name" in
    */*|.|..) continue ;;
  esac
  target="extra/srcpkgs/$target_name"
  [ -d "$target" ] && [ ! -L "$target" ] && [ -f "$target/template" ] || continue
  rm -rf "/void-packages/srcpkgs/$template_name"
  ln -s "$target_name" "/void-packages/srcpkgs/$template_name"
done
chown -R builder:builder /void-packages/srcpkgs /void-packages/common
