#!/usr/bin/env bash
# Push OCO templates to VUR and report results as commit statuses.
set -euo pipefail

VUR_REPO="${VUR_REPO:-oSoWoSo/VUR}"
API_ROOT="${API_ROOT:-https://api.github.com/repos/${VUR_REPO}}"
GITHUB_API_ROOT="${GITHUB_API_ROOT:-https://api.github.com/repos/oSoWoSo/oco}"
EVENT_NAME="${EVENT_NAME:-workflow_dispatch}"
# Overridable for tests; defaults to the live repository.
VUR_GIT_URL="${VUR_GIT_URL:-}"

# Skip when VUR_TOKEN missing (fork PRs).
if [ -z "${VUR_TOKEN:-}" ]; then
        echo "::notice::VUR_TOKEN unavailable (fork pull request?); skipping VUR check"
        exit 0
fi
[ -n "$VUR_GIT_URL" ] || VUR_GIT_URL="https://x-access-token:${VUR_TOKEN}@github.com/${VUR_REPO}.git"

# --- Resolve the list of templates to test -------------------------------

if [ "$EVENT_NAME" = "pull_request" ]; then
        [ -n "${PR_BASE_SHA:-}" ] && [ -n "${PR_HEAD_SHA:-}" ] \
                || { echo "::error::PR_BASE_SHA and PR_HEAD_SHA are required for pull_request events"; exit 1; }
        TEMPLATES="$(git diff --name-status "$PR_BASE_SHA" "$PR_HEAD_SHA" -- 'srcpkgs/*' |
                awk '$1 ~ /^[ACMR]/ { if (substr($1,1,1)=="R") print $3; else print $2 }' |
                cut -d/ -f2 | sort -u | tr '\n' ' ' | sed 's/ $//')"
        [ -n "$TEMPLATES" ] || { echo "::notice::no templates changed in this PR; nothing to test in VUR"; exit 0; }
else
        [ -n "${TEMPLATE:-}" ] || { echo "::error::TEMPLATE is required for workflow_dispatch"; exit 1; }
        TEMPLATES="$TEMPLATE"
fi

if [ "$EVENT_NAME" = "pull_request" ]; then
        [ -n "${PR_NUMBER:-}" ] || { echo "::error::PR_NUMBER is required for pull_request events"; exit 1; }
        [ -n "${HEAD_SHA:-}" ] || { echo "::error::HEAD_SHA is required for pull_request events"; exit 1; }
        [ -n "${GITHUB_TOKEN:-}" ] || { echo "::error::GITHUB_TOKEN is required for pull_request events"; exit 1; }
fi
report_codeberg=0
[ "$EVENT_NAME" = "pull_request" ] && [ -n "${CODEBERG_TOKEN:-}" ] && report_codeberg=1

# --- Report helpers -------------------------------------------------------

# Post a commit status to the OCO repo (requires statuses: write).
github_status() {
        local sha="$1" state="$2" context="$3" description="$4" url="${5:-}"
        local payload
        payload="$(jq -n \
                --arg state "$state" \
                --arg context "${context:0:64}" \
                --arg description "${description:0:140}" \
                --arg url "$url" \
                '{state: $state, context: $context, description: $description, target_url: $url} | if .target_url == "" then del(.target_url) else . end')"
        curl -fsS -X POST -H "Authorization: Bearer ${GITHUB_TOKEN}" \
                -H "Accept: application/vnd.github+json" \
                "${GITHUB_API_ROOT}/statuses/${sha}" \
                -d "$payload" >/dev/null 2>&1 \
                || echo "::warning::failed to post GitHub status ${context}@${sha:0:10}"
}

# Report a check result to the PR head SHA on GitHub and its Codeberg mirror.
report() {
        local sha="$1" state="$2" context="$3" description="$4" url="${5:-}"
        github_status "$sha" "$state" "$context" "$description" "$url"
        if [ "$report_codeberg" = 1 ]; then
                CODEBERG_TOKEN="$CODEBERG_TOKEN" COMMIT_SHA="$sha" \
                        STATUS_STATE="$state" STATUS_CONTEXT="$context" \
                        STATUS_DESCRIPTION="$description" TARGET_URL="$url" \
                        python3 "${GITHUB_WORKSPACE}/.github/scripts/codeberg-status.py" \
                        || echo "::warning::failed to post Codeberg status ${context}@${sha:0:10}"
        fi
}

# --- Push each template and wait for VUR's official build -----------------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --quiet --depth 1 --branch master \
        "$VUR_GIT_URL" \
        "$WORK/vur"
cd "$WORK/vur"
git config user.name "oSoWoSo-bot"
git config user.email "mail@osowoso.org"

# Compute templates to carry via vur-closure.py.
ls srcpkgs > "$WORK/vur-template-dirs.txt"
CARRY="$(python3 "${GITHUB_WORKSPACE}/.github/scripts/vur-closure.py" \
        --root "${GITHUB_WORKSPACE}" \
        --changed "$TEMPLATES" \
        --upstream "$WORK/vur-template-dirs.txt")" \
        || { echo "::error::dependency closure computation failed"; exit 1; }
[ -n "$CARRY" ] || { echo "::notice::no templates to test in VUR"; exit 0; }
echo "::notice::carrying $(printf '%s\n' "$CARRY" | wc -l) template(s): $(printf '%s' "$CARRY" | tr '\n' ' ')"

if [ "$EVENT_NAME" = "pull_request" ]; then
        BRANCH="ci-pr-${PR_NUMBER}"
else
        BRANCH="ci-${TEMPLATE}"
fi
case "$BRANCH" in
        ''|-*|*/*|*--*|*..*|*' '*|*$'\\'*|*$'\t'*) echo "::error::invalid branch name: $BRANCH"; exit 1 ;;
esac

pushed_branches=()
declare -A before_run_id

push_template() {
        local template="$1" src pkgname version
        src="${GITHUB_WORKSPACE}/srcpkgs/${template}"
        # Resolve symlinked srcpkgs entries (CRC-* -> Community-Repositories-Collection).
        if [ -L "$src" ]; then src="$(readlink -f "$src")"; fi
        [ -d "$src" ] || { echo "::error::template not found: srcpkgs/${template}"; return 1; }

        pkgname="$(sed -n 's/^pkgname=//p' "$src/template" | head -n1 | tr -d '"' | tr -d ' ')"
        pkgname="${pkgname:-$template}"

        # Track whether package exists upstream for commit message.
        if [ -e "srcpkgs/${template}/template" ]; then
                upstream_template=1
        else
                upstream_template=0
        fi

        # Overlay the OCO template directory.
        rm -rf "srcpkgs/${template}"
        cp -a "$src" "srcpkgs/${template}"

        # Carry symlinked template under real name too, without clobbering upstream.
        if [ "${src##*/}" != "$template" ] && [ ! -e "srcpkgs/${src##*/}" ]; then
                cp -a "$src" "srcpkgs/${src##*/}"
                git add "srcpkgs/${src##*/}"
        fi

        # Carry subpackage aliases (xbps-src resolves srcpkgs/<subpkg>/template).
        for _link in "${GITHUB_WORKSPACE}"/srcpkgs/*; do
                [ -L "$_link" ] || continue
                [ "${_link##*/}" != "$template" ] || continue
                [ "$(readlink -f "$_link")" = "$(readlink -f "$src")" ] || continue
                rm -rf "srcpkgs/${_link##*/}"
                ln -s "$(readlink "$_link")" "srcpkgs/${_link##*/}"
                git add "srcpkgs/${_link##*/}"
        done

        # Apply the OCO shlibs changes that concern this package.
        append_shlibs() {
                local line pkgver
                [ -f "${GITHUB_WORKSPACE}/shlibs_append" ] || return 0
                while IFS= read -r line; do
                        [ -n "$line" ] || continue
                        pkgver="${line##* }"
                        case "$pkgver" in
                                "$pkgname-"*|"$template-"*) ;;
                                *) continue ;;
                        esac
                        grep -qxF "$line" common/shlibs || echo "$line" >> common/shlibs
                done <"${GITHUB_WORKSPACE}/shlibs_append"
        }
        remove_shlibs() {
                local line pkgver
                [ -f "${GITHUB_WORKSPACE}/shlibs_remove" ] || return 0
                while IFS= read -r line; do
                        [ -n "$line" ] || continue
                        pkgver="${line##* }"
                        case "$pkgver" in
                                "$pkgname-"*|"$template-"*) ;;
                                *) continue ;;
                        esac
                        if grep -qxF "$line" common/shlibs; then
                                grep -vxF "$line" common/shlibs > common/shlibs.tmp || true
                                mv -f common/shlibs.tmp common/shlibs
                        fi
                done <"${GITHUB_WORKSPACE}/shlibs_remove"
        }
        append_shlibs
        remove_shlibs

        # Flag pushed only if this template staged new changes.
        _before="$(git diff --cached --name-only)"
        git add "srcpkgs/${template}" common/shlibs
        _after="$(git diff --cached --name-only)"
        if [ "$_before" = "$_after" ]; then
                echo "::notice::nothing to test: srcpkgs/${template} already matches void-packages"
                return 1
        fi
        # Carry OCO srcpkgs symlinks (e.g. *-devel aliases) so subpackages resolve.
        for _link in "${GITHUB_WORKSPACE}"/srcpkgs/*; do
                [ -L "$_link" ] || continue
                _name="${_link##*/}"
                _raw_target="$(readlink "$_link")"
                # Skip non-relative targets.
                case "$_raw_target" in
                        /*|*/*|..|.) continue ;;
                esac
                if [ -e "srcpkgs/${_name}" ] || [ -L "srcpkgs/${_name}" ]; then
                        continue
                fi
                ln -s "$_raw_target" "srcpkgs/${_name}"
                git add "srcpkgs/${_name}"
        done

        pushed_branches+=("${template}")
}

# Stage all carried templates onto one test branch.
git checkout --quiet -B "$BRANCH" origin/master
for template in $CARRY; do
        push_template "$template" || continue
done

if [ "${#pushed_branches[@]}" -eq 0 ]; then
        echo "::notice::nothing to test: all carried templates already match void-packages"
        exit 0
fi

if [ "$EVENT_NAME" = "pull_request" ]; then
        context="ci/vur"
        commit_msg="VUR check: $(printf '%s' "${pushed_branches[*]}" | tr ' ' ',')"
else
        context="ci/vur/${pushed_branches[0]}"
        # Follow void-packages CONTRIBUTING.md for manual single-template checks.
        template="${pushed_branches[0]}"
        version="$(sed -n 's/^version=//p' "srcpkgs/${template}/template" | head -n1 | tr -d '"' | tr -d ' ')"
        if [ "$upstream_template" -eq 0 ]; then
                commit_msg="New package: ${template}-${version}"
        else
                commit_msg="${template}: update to ${version}."
        fi
fi
git commit --quiet -m "$commit_msg"

# Record newest run id before push.
before_run_id["$BRANCH"]="$(curl -fsS -H "Authorization: Bearer ${VUR_TOKEN}" \
        "${API_ROOT}/actions/workflows/build.yaml/runs?branch=${BRANCH}&per_page=1" \
        2>/dev/null | jq -r '.workflow_runs[0].id // 0')"
git push --quiet --force origin "HEAD:${BRANCH}"
echo "::notice::pushed https://github.com/${VUR_REPO}/tree/${BRANCH}"

if [ "$EVENT_NAME" != "pull_request" ]; then
        exit 0
fi

# --- Wait for build.yaml run on the pushed branch -------------------------

# Poll for the build run triggered by our push.
update_run_result() {
        local branch="$1" min_id="$2"
        curl -fsS -H "Authorization: Bearer ${VUR_TOKEN}" \
                "${API_ROOT}/actions/workflows/build.yaml/runs?branch=${branch}&per_page=3" \
                2>/dev/null | jq -r --argjson min "$min_id" \
                '[.workflow_runs[] | select(.id > $min)] | .[0] | [.status, (.conclusion // ""), .id, .html_url] | @tsv' |
                head -n1
}

echo "::group::Waiting for VUR build: ${BRANCH} ($(printf '%s' "${pushed_branches[*]}"))"
report "$HEAD_SHA" pending "$context" \
        "VUR build queued" \
        "https://github.com/${VUR_REPO}/actions/workflows/build.yaml"
result=""
min_id="${before_run_id[$BRANCH]:-0}"
for _ in $(seq 1 180); do
        sleep 10
        read -r status conclusion _id html_url <<<"$(update_run_result "$BRANCH" "$min_id")"
        if [ "$status" = "completed" ]; then
                if [ "$conclusion" = "success" ]; then
                        result="success"
                        report "$HEAD_SHA" success "$context" \
                                "VUR build passed" "$html_url"
                else
                        result="failure"
                        report "$HEAD_SHA" failure "$context" \
                                "VUR build ${conclusion:-failed}" "$html_url"
                fi
                break
        fi
done
if [ -z "$result" ]; then
        report "$HEAD_SHA" error "$context" \
                "VUR build timed out after 30m" \
                "https://github.com/${VUR_REPO}/actions/workflows/build.yaml"
fi
echo "::endgroup::"

# The job exits non-zero if the check failed, so the PR check reflects failure.
state="$(curl -fsS -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        "${GITHUB_API_ROOT}/statuses/${HEAD_SHA}" \
        2>/dev/null | jq -r --arg ctx "$context" \
        '[.[] | select(.context == $ctx)] | sort_by(.created_at) | .[-1].state' |
        head -n1)"
[ "$state" = "success" ] || exit 1
