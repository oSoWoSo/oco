#!/usr/bin/env bash
set -euo pipefail
. src/pkg-helpers.sh
packages=""
removed=""

# Debug output
echo "DEBUG: INPUT_ALL=$INPUT_ALL"
echo "DEBUG: INPUT_TEMPLATE=$INPUT_TEMPLATE"
echo "DEBUG: EVENT_NAME=$EVENT_NAME"
echo "DEBUG: CURRENT_BRANCH=$CURRENT_BRANCH"
echo "DEBUG: PUSH_BEFORE=$PUSH_BEFORE"
echo "DEBUG: PUSH_AFTER=$PUSH_AFTER"

# Auto-merged autobump PRs are published from their successful PR
# artifacts by autobump-release.yml. Never compile them again on OCO.
skip_autobump=false
if [ "$EVENT_NAME" = push ] && [ "$GITHUB_REF" = refs/heads/OCO ]; then
  _message=$(git log -1 --format=%B "$PUSH_AFTER" 2>/dev/null || true)
  if printf '%s\n' "$_message" | grep -Eq '^OCO-Autobump-Run: [0-9]+$'; then
    _associated=''
    for _try in 1 2 3 4 5; do
      _associated=$(gh api "repos/${GITHUB_REPOSITORY}/commits/${PUSH_AFTER}/pulls?per_page=100" \
        | jq -r --arg repo "$GITHUB_REPOSITORY" \
          '.[] | select(.merged_at != null and .base.ref == "OCO" and .head.repo.full_name == $repo and (.user.login == "oSoWoSo-bot" or .user.login == "zen0bit" or .user.login == "zenobit") and (.head.ref | startswith("autobump/"))) | .number' \
        ) && [ -n "$_associated" ] && break
      sleep 3
    done
    if [ -z "$_associated" ]; then
      echo "::error::Autobump merge marker present, but no matching merged PR was verified"
      exit 1
    fi
    echo "Autobump merge #${_associated} uses PR build artifacts; skip recompilation"
    skip_autobump=true
  fi
fi
echo "skip_autobump=$skip_autobump" >> "$GITHUB_OUTPUT"

# Fail closed: only an exact OCO ref may publish production, and
# only ordinary OCO pushes are implicitly production. Dispatch must
# explicitly choose production; repository_dispatch stays testing.
publish_target=testing
if [ "$GITHUB_REF" = "refs/heads/OCO" ]; then
  if [ "$EVENT_NAME" = push ] || \
     { [ "$EVENT_NAME" = workflow_dispatch ] && [ "$INPUT_PUBLISH_TARGET" = production ]; }; then
    publish_target=production
  fi
fi
repository_prefix=testing
[ "$publish_target" = production ] && repository_prefix=''
echo "publish_target=$publish_target" >> "$GITHUB_OUTPUT"
echo "repository_prefix=$repository_prefix" >> "$GITHUB_OUTPUT"

ZERO_SHA="0000000000000000000000000000000000000000"
all_packages() {
  list_srcpkgs srcpkgs | tr '\n' ' ' | sed 's/ $//'
}

if [ "$INPUT_ALL" = "true" ]; then
  packages=$(all_packages)
elif [ -n "$INPUT_TEMPLATE" ]; then
  packages="$INPUT_TEMPLATE"
elif [ -n "$INPUT_TEMPLATES" ]; then
  packages=$(printf '%s ' $INPUT_TEMPLATES | sed 's/ $//')
elif [ "$EVENT_NAME" = "push" ] || [ "$EVENT_NAME" = "pull_request" ]; then
  BASE_SHA=""
  HEAD_SHA=""
  UNCERTAIN_OCO_BASE=false
  if [ "$EVENT_NAME" = "pull_request" ]; then
    BASE_SHA="$PR_BASE_SHA"
    HEAD_SHA="$PR_HEAD_SHA"
  else
    HEAD_SHA="$PUSH_AFTER"
    if [ "$CURRENT_BRANCH" = "OCO" ]; then
      # Push event SHAs are immutable. Do not substitute the moving
      # branch tip (or HEAD^) when the exact before commit is absent.
      if [ -z "$PUSH_BEFORE" ] || [ "$PUSH_BEFORE" = "$ZERO_SHA" ]; then
        UNCERTAIN_OCO_BASE=true
      else
        if ! git cat-file -e "$PUSH_BEFORE" 2>/dev/null; then
          git fetch --no-tags origin "$PUSH_BEFORE" >/dev/null 2>&1 || true
        fi
        if git cat-file -e "$PUSH_BEFORE" 2>/dev/null; then
          BASE_SHA="$PUSH_BEFORE"
        else
          UNCERTAIN_OCO_BASE=true
        fi
      fi
    else
      BASE_SHA="$ZERO_SHA"
    fi
  fi
  echo "DEBUG: BASE_SHA=$BASE_SHA"
  echo "DEBUG: HEAD_SHA=$HEAD_SHA"
  if [ "$UNCERTAIN_OCO_BASE" = "true" ]; then
    echo "::warning::OCO push before SHA is zero or unavailable; building all packages without inferring removals"
    packages=$(all_packages)
  elif [ -z "$BASE_SHA" ] || [ "$BASE_SHA" = "$ZERO_SHA" ] \
      || ! git cat-file -e "$BASE_SHA" 2>/dev/null; then
    echo "No direct diff base; reading origin/OCO .gitignore for package list"
    _main_list=$(git show origin/OCO:.gitignore 2>/dev/null | sed -n 's|^!/srcpkgs/\([^/]*\)/*$|\1|p' | sort -fu || true)
    if [ -n "$_main_list" ]; then
      _current_list=$(list_srcpkgs srcpkgs)
      _added=$(  grep -Fxvf <(printf '%s\n' "$_main_list") <(printf '%s\n' "$_current_list") || true)
      _removed=$(grep -Fxvf <(printf '%s\n' "$_current_list") <(printf '%s\n' "$_main_list") || true)
      removed=$(printf '%s\n' "$_removed" | tr '\n' ' ' | sed 's/ $//')
      _common=$( grep -Fxf  <(printf '%s\n' "$_main_list") <(printf '%s\n' "$_current_list") || true)
      _modified=""
      for _pkg in $_common; do
        if git show origin/OCO:srcpkgs/$_pkg/template 2>/dev/null \
            | diff -q - srcpkgs/$_pkg/template >/dev/null 2>&1; then
          :
        else
          _modified="$_modified$_pkg "
        fi
      done
      packages=$(printf '%s\n%s' "$_added" "$_modified" | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')
    else
      echo "  Warning: origin/OCO:.gitignore empty or not found; building all packages"
      packages=$(all_packages)
    fi
  else
    _diff=$(git diff --name-status "$BASE_SHA" "$HEAD_SHA" -- 'srcpkgs/*')
    packages=$(printf '%s\n' "$_diff" \
      | awk '$1 ~ /^[ACMR]/ { if (substr($1,1,1)=="R") print $3; else print $2 }' \
      | cut -d/ -f2 | sort -u | tr '\n' ' ' | sed 's/ $//')
    removed=$(printf '%s\n' "$_diff" \
      | awk '$1=="D"{print $2} $1~/^R/{print $2}' \
      | cut -d/ -f2 | sort -u | tr '\n' ' ' | sed 's/ $//')
  fi
else
  packages=$(all_packages)
fi

_filtered=""
for _pkg in $packages; do
  if [ -L "srcpkgs/$_pkg" ]; then
    echo "::warning::$_pkg is an alias for $(basename "$(readlink "srcpkgs/$_pkg")"), skipping"
    continue
  fi
  _filtered="$_filtered $_pkg"
done
packages="${_filtered# }"

echo "Packages: ${packages:-<none>}"
echo "Removed: ${removed:-<none>}"
echo "packages=$packages" >> "$GITHUB_OUTPUT"
echo "removed=$removed" >> "$GITHUB_OUTPUT"
repo="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"
ref="${GITHUB_REF_NAME//\//%2F}"
echo "| Package | version | template |" >> "$GITHUB_STEP_SUMMARY"
echo "|---------|---------|----------|" >> "$GITHUB_STEP_SUMMARY"
for pkg in $packages; do
  version=$(grep '^version=' "srcpkgs/${pkg}/template" 2>/dev/null | cut -d '=' -f2 || true)
  echo "| $pkg | $version | [template](${repo}/blob/${ref}/srcpkgs/${pkg}/template) |" >> "$GITHUB_STEP_SUMMARY"
done

# Topological build order: show inter-package deps within the detected set
_topo_pkg_deps() {
  local _pkg="$1" _tpl="srcpkgs/$1/template" _field _line _dep _dep_name
  [ -f "$_tpl" ] || return 0
  for _field in hostmakedepends makedepends depends; do
    _line=$(grep -m1 "^${_field}=" "$_tpl" 2>/dev/null || true)
    _line="${_line#*=}"; _line="${_line#\"}"; _line="${_line%\"}"; _line="${_line#\'}"; _line="${_line%\'}"
    for _dep in $_line; do
      _dep_name="${_dep%%[><=]*}"
      [ -z "$_dep_name" ] && continue
      case " $packages " in *" $_dep_name "*) echo "$_dep_name" ;; esac
    done
  done
}
_topo_visited=""; _topo_sorted=""
_topo_visit() {
  local _v="$1"
  case " $_topo_visited " in *" $_v "*) return ;; esac
  _topo_visited="$_topo_visited $_v"
  for _d in $(_topo_pkg_deps "$_v"); do _topo_visit "$_d"; done
  _topo_sorted="$_topo_sorted $_v"
}
for _p in $packages; do _topo_visit "$_p"; done
echo "" >> "$GITHUB_STEP_SUMMARY"
echo "### build order" >> "$GITHUB_STEP_SUMMARY"
echo "" >> "$GITHUB_STEP_SUMMARY"
_ord=1
for _p in $_topo_sorted; do
  # Subpackage template-symlinks are reported under their parent below;
  # skip them here unless their parent is not in the detected set.
  if [ -L "srcpkgs/$_p" ]; then
    _p_parent=$(readlink "srcpkgs/$_p")
    case " $_topo_sorted " in *" $_p_parent "*) continue ;; esac
  fi
  _deps=$(_topo_pkg_deps "$_p" | sort -u | tr '\n' ' ' | sed 's/ $//')
  if [ -n "$_deps" ]; then
    echo "${_ord}. **${_p}** ← ${_deps}" >> "$GITHUB_STEP_SUMMARY"
  else
    echo "${_ord}. **${_p}**" >> "$GITHUB_STEP_SUMMARY"
  fi
  _ord=$((_ord + 1))
done

# Subpackages = symlinks in srcpkgs/ pointing at a listed package's template dir,
# grouped under their parent package.
_sub_parents=""
for _p in $_topo_sorted; do
  [ -L "srcpkgs/$_p" ] && continue
  for _sp in srcpkgs/*; do
    [ -L "$_sp" ] || continue
    [ "$(readlink "$_sp")" = "$_p" ] && { _sub_parents="$_sub_parents $_p"; break; }
  done
done
if [ -n "$_sub_parents" ]; then
  echo "" >> "$GITHUB_STEP_SUMMARY"
  echo "### subpackages" >> "$GITHUB_STEP_SUMMARY"
  echo "" >> "$GITHUB_STEP_SUMMARY"
  for _p in $_sub_parents; do
    _children=""
    for _sp in srcpkgs/*; do
      [ -L "$_sp" ] || continue
      [ "$(readlink "$_sp")" = "$_p" ] && _children="$_children ${_sp##*/}"
    done
    echo "**${_p}**:" >> "$GITHUB_STEP_SUMMARY"
    for _c in $_children; do
      echo "- $_c" >> "$GITHUB_STEP_SUMMARY"
    done
  done
fi

if [ -n "$removed" ]; then
  echo "" >> "$GITHUB_STEP_SUMMARY"
  echo "### Removed" >> "$GITHUB_STEP_SUMMARY"
  echo "" >> "$GITHUB_STEP_SUMMARY"
  for pkg in $removed; do
    echo "$pkg" >> "$GITHUB_STEP_SUMMARY"
  done
fi

arch_needed() {
  local target="$1"
  for pkg in $packages; do
    pkg_arch_ok "$pkg" "$target" && return 0
  done
  return 1
}

needs_cross() {
  local target="$1"
  _cnc_visited=""
  local any_nocross=0
  for pkg in $packages; do
    local template="srcpkgs/${pkg}/template"
    [ -f "$template" ] || continue
    pkg_arch_ok "$pkg" "$target" || continue
    _check_nocross_chain "$pkg" && any_nocross=1
  done
  [ "$any_nocross" = 0 ] && arch_needed "$target"
}

needs_native() {
  local target="$1"
  _cnc_visited=""
  for pkg in $packages; do
    local template="srcpkgs/${pkg}/template"
    [ -f "$template" ] || continue
    _check_nocross_chain "$pkg" || continue
    pkg_arch_ok "$pkg" "$target" && return 0
  done
  return 1
}

add_cfg() {
  [ -n "$matrix_configs" ] && matrix_configs="${matrix_configs},"
  matrix_configs="${matrix_configs}{\"arch\":\"$1\",\"host\":\"$2\",\"runner\":\"$3\",\"platform\":\"$4\",\"test\":$5,\"native\":$6}"
}

_RUNNER="${INPUT_RUNNER:-auto}"
case "$_RUNNER" in
  amd64)
    _amd64=$(arch_needed "x86_64" && echo 1 || echo 0)
    _musl=$(arch_needed "x86_64-musl" && echo 1 || echo 0)
    matrix_configs=""
    [ "$_amd64" = 1 ]           && add_cfg "x86_64"       "x86_64"  "ubuntu-latest"    "linux/amd64" 1 false
    [ "$_musl"  = 1 ]           && add_cfg "x86_64-musl"  "x86_64"  "ubuntu-latest"    "linux/amd64" 1 false
    if [ -z "$matrix_configs" ]; then
      echo "Warning: no packages for amd64 archs, defaulting to x86_64" >> "$GITHUB_STEP_SUMMARY"
                                   add_cfg "x86_64"       "x86_64"  "ubuntu-latest"    "linux/amd64" 1 false
    fi
    ;;
  arm64)
    _arm_native=$(arch_needed "aarch64" && echo 1 || echo 0)
    _arm_musl=$(arch_needed "aarch64-musl" && echo 1 || echo 0)
    matrix_configs=""
    [ "$_arm_native" = 1 ]      && add_cfg "aarch64"      "aarch64" "ubuntu-24.04-arm" "linux/arm64" 1 true
    [ "$_arm_musl"  = 1 ]      && add_cfg "aarch64-musl" "aarch64-musl" "ubuntu-24.04-arm" "linux/arm64" 1 true
    if [ -z "$matrix_configs" ]; then
      echo "Warning: no packages for arm64 archs, defaulting to x86_64" >> "$GITHUB_STEP_SUMMARY"
                                   add_cfg "x86_64"       "x86_64"  "ubuntu-latest"    "linux/amd64" 1 false
    fi
    ;;
  nocross)
    matrix_configs=""
    arch_needed "x86_64"        && add_cfg "x86_64"       "x86_64"  "ubuntu-latest"    "linux/amd64" 1 false
    arch_needed "aarch64"       && add_cfg "aarch64"      "aarch64" "ubuntu-24.04-arm" "linux/arm64" 1 true
    arch_needed "x86_64-musl"   && add_cfg "x86_64-musl"  "x86_64"  "ubuntu-latest"    "linux/amd64" 1 false
    arch_needed "aarch64-musl"  && add_cfg "aarch64-musl" "aarch64-musl" "ubuntu-24.04-arm" "linux/arm64" 1 true
    if [ -z "$matrix_configs" ]; then
      echo "Warning: no packages for any arch, defaulting to x86_64" >> "$GITHUB_STEP_SUMMARY"
                                   add_cfg "x86_64"       "x86_64"  "ubuntu-latest"    "linux/amd64" 1 false
    fi
    ;;
  self-hosted)
    matrix_configs=""
    arch_needed "x86_64"        && add_cfg "x86_64"       "x86_64"  "self-hosted"      "linux/amd64" 1 false
    needs_cross "aarch64"       && add_cfg "aarch64"      "x86_64"  "self-hosted"      "linux/amd64" 0 false
    arch_needed "x86_64-musl"   && add_cfg "x86_64-musl"  "x86_64"  "self-hosted"      "linux/amd64" 1 false
    needs_cross "aarch64-musl"  && add_cfg "aarch64-musl" "x86_64"  "self-hosted"      "linux/amd64" 0 false
    needs_native "aarch64"      && add_cfg "aarch64"      "aarch64" "self-hosted"      "linux/arm64" 1 true
    needs_native "aarch64-musl" && add_cfg "aarch64-musl" "aarch64-musl" "self-hosted"      "linux/arm64" 1 true
    if [ -z "$matrix_configs" ]; then
      echo "Warning: no arch matched package list, defaulting to x86_64" >> "$GITHUB_STEP_SUMMARY"
                                   add_cfg "x86_64"       "x86_64"  "self-hosted"      "linux/amd64" 1 false
    fi
    ;;
  auto|*)
    matrix_configs=""
    arch_needed "x86_64"        && add_cfg "x86_64"       "x86_64"  "ubuntu-latest"    "linux/amd64" 1 false
    needs_cross "aarch64"       && add_cfg "aarch64"      "x86_64"  "ubuntu-latest"    "linux/amd64" 0 false
    arch_needed "x86_64-musl"   && add_cfg "x86_64-musl"  "x86_64"  "ubuntu-latest"    "linux/amd64" 1 false
    needs_cross "aarch64-musl"  && add_cfg "aarch64-musl" "x86_64"  "ubuntu-latest"    "linux/amd64" 0 false
    needs_native "aarch64"      && add_cfg "aarch64"      "aarch64" "ubuntu-24.04-arm" "linux/arm64" 1 true
    needs_native "aarch64-musl" && add_cfg "aarch64-musl" "aarch64-musl" "ubuntu-24.04-arm" "linux/arm64" 1 true
    if [ -z "$matrix_configs" ]; then
      echo "Warning: no arch matched package list, defaulting to x86_64" >> "$GITHUB_STEP_SUMMARY"
                                   add_cfg "x86_64"       "x86_64"  "ubuntu-latest"    "linux/amd64" 1 false
    fi
    ;;
esac
echo "matrix={\"config\":[${matrix_configs}]}" >> "$GITHUB_OUTPUT"
