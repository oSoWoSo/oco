#!/usr/bin/env bash
# Push OCO template(s) to oSoWoSo/VUR so VUR's check-anywhere workflow
# (the official void-packages checks) runs against them, then report the
# run results back as commit statuses on the OCO PR (GitHub + Codeberg).
#
# Two modes:
#   - workflow_dispatch: tests the single TEMPLATE input.
#   - pull_request: tests every srcpkgs/* template changed between the PR
#     base and head (diff PR_BASE_SHA..PR_HEAD_SHA).
#
# Every push to OCO/<template> in VUR triggers check-anywhere (it runs on
# any push touching srcpkgs/**); we wait for that run and post its outcome
# as ci/vur/<template> on the PR head SHA on both forges.
#
# Required env: VUR_TOKEN. Plus, for PR events: PR_BASE_SHA, PR_HEAD_SHA,
# HEAD_SHA, GITHUB_TOKEN, CODEBERG_TOKEN, PR_NUMBER.
set -euo pipefail

VUR_REPO="${VUR_REPO:-oSoWoSo/VUR}"
API_ROOT="${API_ROOT:-https://api.github.com/repos/${VUR_REPO}}"
GITHUB_API_ROOT="${GITHUB_API_ROOT:-https://api.github.com/repos/oSoWoSo/oco}"
EVENT_NAME="${EVENT_NAME:-workflow_dispatch}"
# Overridable for tests; defaults to the live repository.
VUR_GIT_URL="${VUR_GIT_URL:-}"

# Skip when we lack a token with write access to VUR (fork PRs): the
# read-only GITHUB_TOKEN cannot push branches. In pull_request events from
# forks secrets.BOT is unavailable (empty), so VUR_TOKEN is empty here.
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

for template in $TEMPLATES; do
        case "$template" in
                ''|-*|*/*|*--*|*..*|*' '*|*$'\\'*|*$'\t'*) echo "::error::invalid template name: $template"; exit 1 ;;
        esac
done

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
                        python3 "${GITHUB_WORKSPACE}/.github/scripts/ci/codeberg-status.py" \
                        || echo "::warning::failed to post Codeberg status ${context}@${sha:0:10}"
        fi
}

# --- Push each template and wait for VUR's check-anywhere -----------------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --quiet --depth 1 --branch VUR \
        "$VUR_GIT_URL" \
        "$WORK/vur"
cd "$WORK/vur"
git config user.name "oSoWoSo-bot"
git config user.email "mail@osowoso.org"

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

        # Rebase the test branch on the latest VUR (synced from void master).
        git checkout --quiet -B "OCO/${template}" origin/VUR 2>/dev/null

        # Overlay the OCO template directory.
        rm -rf "srcpkgs/${template}"
        cp -a "$src" "srcpkgs/${template}"

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

        git add "srcpkgs/${template}" common/shlibs
        if git diff --cached --quiet; then
                echo "::notice::nothing to test: srcpkgs/${template} already matches void-packages"
                return 1
        fi

        version="$(sed -n 's/^version=//p' "srcpkgs/${template}/template" | head -n1 | tr -d '"' | tr -d ' ')"
        git commit --quiet -m "${pkgname} ${version} (from OCO)"
        # Record the newest run already on the branch so the wait loop can
        # tell our fresh run apart from a stale completed one (the API can
        # briefly lag behind the push).
        before_run_id[$template]="$(curl -fsS -H "Authorization: Bearer ${VUR_TOKEN}" \
                "${API_ROOT}/actions/workflows/check-anywhere.yml/runs?branch=OCO%2F${template}&per_page=1" \
                2>/dev/null | jq -r '.workflow_runs[0].id // 0')"
        git push --quiet --force origin "HEAD:OCO/${template}"
        echo "::notice::pushed https://github.com/${VUR_REPO}/tree/OCO/${template}"
        pushed_branches+=("${template}")
}

for template in $TEMPLATES; do
        push_template "$template" || continue
done

if [ "$EVENT_NAME" != "pull_request" ] || [ "${#pushed_branches[@]}" -eq 0 ]; then
        exit 0
fi

# --- Wait for check-anywhere runs on the pushed branches ------------------

# The check-anywhere run triggered by our push is the newest one whose id is
# greater than the run that existed on the branch before the push (the API
# can briefly lag behind the push). It begins as 'queued' and moves to
# 'completed'. Poll up to 30 minutes.
update_run_result() {
        local template="$1" min_id="$2"
        curl -fsS -H "Authorization: Bearer ${VUR_TOKEN}" \
                "${API_ROOT}/actions/workflows/check-anywhere.yml/runs?branch=OCO%2F${template}&per_page=3" \
                2>/dev/null | jq -r --argjson min "$min_id" \
                '[.workflow_runs[] | select(.id > $min)] | .[0] | [.status, (.conclusion // ""), .id, .html_url] | @tsv' |
                head -n1
}

for template in "${pushed_branches[@]}"; do
        echo "::group::Waiting for VUR check-anywhere: ${template}"
        report "$HEAD_SHA" pending "ci/vur/${template}" \
                "VUR check-anywhere queued" \
                "https://github.com/${VUR_REPO}/actions/workflows/check-anywhere.yml"
        result=""
        min_id="${before_run_id[$template]:-0}"
        for _ in $(seq 1 180); do
                sleep 10
                read -r status conclusion _id html_url <<<"$(update_run_result "$template" "$min_id")"
                if [ "$status" = "completed" ]; then
                        if [ "$conclusion" = "success" ]; then
                                result="success"
                                report "$HEAD_SHA" success "ci/vur/${template}" \
                                        "VUR check-anywhere passed" "$html_url"
                        else
                                result="failure"
                                report "$HEAD_SHA" failure "ci/vur/${template}" \
                                        "VUR check-anywhere ${conclusion:-failed}" "$html_url"
                        fi
                        break
                fi
        done
        if [ -z "$result" ]; then
                report "$HEAD_SHA" error "ci/vur/${template}" \
                        "VUR check-anywhere timed out after 30m" \
                        "https://github.com/${VUR_REPO}/actions/workflows/check-anywhere.yml"
        fi
        echo "::endgroup::"
done

# The job exits non-zero if any check failed, so the PR check reflects failure.
for template in "${pushed_branches[@]}"; do
        state="$(curl -fsS -H "Authorization: Bearer ${GITHUB_TOKEN}" \
                "${GITHUB_API_ROOT}/statuses/${HEAD_SHA}" \
                2>/dev/null | jq -r --arg ctx "ci/vur/${template}" \
                '[.[] | select(.context == $ctx)] | sort_by(.created_at) | .[-1].state' |
                head -n1)"
        [ "$state" = "success" ] || exit 1
done
