#!/usr/bin/env bats
# vur-check.sh must copy an OCO srcpkgs symlink that aliases the template's
# directory onto the VUR test branch. Without it xbps-src aborts with
# "xbps-src: nonexistent file: srcpkgs/<subpkg>/template" when it builds the
# subpackage. These tests run the real push_template() overlay logic against
# a scratch VUR worktree.

setup() {
  TEST_DIR="$(mktemp -d)"
  export TEST_DIR
  export OCO="$TEST_DIR/oco"
  export VUR="$TEST_DIR/vur"
  mkdir -p "$OCO/srcpkgs" "$VUR"
  git init -q -b master "$VUR"
  git -C "$VUR" config user.name "oSoWoSo-bot"
  git -C "$VUR" config user.email "mail@osowoso.org"
  mkdir -p "$VUR/srcpkgs" "$VUR/common"
  : >"$VUR/common/shlibs"
  echo base >"$VUR/base.txt"
  git -C "$VUR" add . && git -C "$VUR" commit -qm base
  # push_template() operates on the current directory's srcpkgs/, so pin the
  # worktree it must touch to the scratch VUR clone -- never the OCO checkout
  # that bats itself is running from.
  cd "$VUR"
  export GITHUB_WORKSPACE="$OCO"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Source push_template() from the real script up to where the template is
# staged and its skip/keep status is decided. The tail (branch commit, push,
# run polling, status reporting) talks to GitHub and is out of scope here.
# The caller must set $template first.
load_push_template() {
  local body
  body="$(awk '
    /^push_template\(\) \{/ {p=1; print; next}
    p && /pushed_branches\+=\("\$\{template\}"\)/ {print; print "}"; p=0; next}
    p {print}
  ' "$BATS_TEST_DIRNAME/../.github/scripts/vur-check.sh")"
  eval "$body"
  # Override the push/commit stubs so push_template() can run to the point
  # where files are staged.
  git() {
    case "${1:-}" in
      -C|add|diff|config|ls-files|cat-file|show) command git "$@" ;;
      *) return 0 ;;
    esac
  }
  export -f git
}

assert_staged_symlink() {
  local link="$1" expect_target="$2"
  local mode blob
  mode="$(git ls-files -s "srcpkgs/$link" | awk '{print $1}')"
  [ "$mode" = "120000" ] || { echo "FAIL: $link is not staged as symlink (mode $mode)"; return 1; }
  blob="$(git ls-files -s "srcpkgs/$link" | awk '{print $2}')"
  [ "$(git cat-file blob "$blob")" = "$expect_target" ] || { echo "FAIL: $link targets '$(git cat-file blob "$blob")', want '$expect_target'"; return 1; }
}

@test "aliases of a plain template dir are copied and staged as symlinks" {
  mkdir -p "$OCO/srcpkgs/fcitx5-lotus/files"
  printf 'pkgname=fcitx5-lotus\nversion=6.0.6\nrevision=1\n' >"$OCO/srcpkgs/fcitx5-lotus/template"
  printf '# readme\n' >"$OCO/srcpkgs/fcitx5-lotus/files/README"
  ln -s fcitx5-lotus "$OCO/srcpkgs/fcitx5-lotus-settings"
  ln -s fcitx5-lotus "$OCO/srcpkgs/fcitx5-lotus-extra"

  template=fcitx5-lotus
  load_push_template
  push_template fcitx5-lotus

  assert_staged_symlink fcitx5-lotus-settings fcitx5-lotus
  assert_staged_symlink fcitx5-lotus-extra fcitx5-lotus
  [ -d "$VUR/srcpkgs/fcitx5-lotus" ]
}

@test "unrelated aliases are never copied" {
  mkdir -p "$OCO/srcpkgs/fcitx5-lotus" "$OCO/srcpkgs/other-pkg"
  printf 'pkgname=fcitx5-lotus\nversion=6.0.6\nrevision=1\n' >"$OCO/srcpkgs/fcitx5-lotus/template"
  printf 'pkgname=other-pkg\nversion=1\nrevision=1\n' >"$OCO/srcpkgs/other-pkg/template"
  ln -s fcitx5-lotus "$OCO/srcpkgs/fcitx5-lotus-settings"
  ln -s other-pkg "$OCO/srcpkgs/unrelated-alias"

  template=fcitx5-lotus
  load_push_template
  push_template fcitx5-lotus

  assert_staged_symlink fcitx5-lotus-settings fcitx5-lotus
  [ ! -e "$VUR/srcpkgs/unrelated-alias" ]
}

@test "a symlinked template carries its real dir name when upstream lacks it" {
  mkdir -p "$OCO/srcpkgs/Community-Repositories-Collection"
  printf 'pkgname=Community-Repositories-Collection\nversion=1\nrevision=11\n' \
    >"$OCO/srcpkgs/Community-Repositories-Collection/template"
  ln -s Community-Repositories-Collection "$OCO/srcpkgs/CRC-black-hole"
  ln -s Community-Repositories-Collection "$OCO/srcpkgs/CRC-cosmic"

  template=CRC-black-hole
  load_push_template
  push_template CRC-black-hole

  # Both the real dir and every alias must resolve to a template.
  for p in srcpkgs/Community-Repositories-Collection/template \
           srcpkgs/CRC-black-hole/template \
           srcpkgs/CRC-cosmic/template; do
    [ -e "$VUR/$p" ] || { echo "FAIL: $p does not resolve"; return 1; }
  done
}

@test "a symlinked template must not clobber an upstream package dir" {
  mkdir -p "$OCO/srcpkgs/btrfs-progs"
  printf 'pkgname=btrfs-progs\nversion=7.1\nrevision=1\n' >"$OCO/srcpkgs/btrfs-progs/template"
  ln -s btrfs-progs "$OCO/srcpkgs/libbtrfsutil"
  ln -s btrfs-progs "$OCO/srcpkgs/libbtrfs-devel"
  # VUR master already ships btrfs-progs itself.
  mkdir -p "$VUR/srcpkgs/btrfs-progs"
  printf 'pkgname=btrfs-progs\nversion=6.0\nrevision=2\n' >"$VUR/srcpkgs/btrfs-progs/template"
  git -C "$VUR" add . && git -C "$VUR" commit -qm upstream

  template=libbtrfsutil
  load_push_template
  push_template libbtrfsutil

  # Upstream template must be byte-identical.
  [ "$(git -C "$VUR" show HEAD:srcpkgs/btrfs-progs/template | grep '^version=')" = "version=6.0" ]
  # The template itself (libbtrfsutil) is overlaid as a real directory, while
  # its sibling alias is copied as a symlink into the same dir.
  [ -f "$VUR/srcpkgs/libbtrfsutil/template" ]
  assert_staged_symlink libbtrfs-devel btrfs-progs
  [ -e "$VUR/srcpkgs/libbtrfs-devel/template" ]
}

@test "two carried templates stage into the same single test branch" {
    mkdir -p "$OCO/srcpkgs/alpha" "$OCO/srcpkgs/beta"
    printf 'pkgname=alpha\nversion=1.0\nrevision=1\n' >"$OCO/srcpkgs/alpha/template"
    printf 'pkgname=beta\nversion=1.0\nrevision=1\n' >"$OCO/srcpkgs/beta/template"

    # The batch driver pushes everything onto one branch: emulate CARRY by
    # overlaying both templates into the same worktree and staging once.
    template=alpha
    load_push_template
    push_template alpha
    push_template beta

    # Both templates resolve from the branch worktree (same staging area).
    [ -f "$VUR/srcpkgs/alpha/template" ]
    [ -f "$VUR/srcpkgs/beta/template" ]
    [ "$(git -C "$VUR" diff --cached --name-only | grep -c '^srcpkgs/')" -ge 2 ]
}

@test "an already-matching carried template is skipped" {
    mkdir -p "$OCO/srcpkgs/alpha"
    printf 'pkgname=alpha\nversion=1.0\nrevision=1\n' >"$OCO/srcpkgs/alpha/template"
    # VUR master already ships the exact same template.
    mkdir -p "$VUR/srcpkgs/alpha"
    printf 'pkgname=alpha\nversion=1.0\nrevision=1\n' >"$VUR/srcpkgs/alpha/template"
    git -C "$VUR" add . && git -C "$VUR" commit -qm upstream

    template=alpha
    load_push_template
    run push_template alpha
    [ "$status" -eq 1 ]
    # Nothing staged by this template.
    [ -z "$(git -C "$VUR" diff --cached --name-only)" ]
}