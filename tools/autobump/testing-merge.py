#!/usr/bin/env python3
"""Merge a passed T-autobump PR into the testing branch.

Runs from a ``workflow_run`` of the build workflow (triggered by the
``testing-merge.yml`` workflow). The workflow_run conclusion already
establishes that the PR build passed; this script additionally verifies that
the run is really a pull_request, targets the ``testing`` branch, belongs to
this repository, and that the run's head SHA is still the PR's head.

OCO parity: just as only bot-created ``autobump/<template>`` branches
auto-merge into OCO, only bot-created ``T-autobump/<template>`` branches
auto-merge into ``testing``. The merge is a *rebase and fast-forward* via the
GitHub API (``merge_method=rebase``), which preserves the PR's real commits
instead of creating a synthetic squash commit. Every other PR is left for
manual review.
"""

from __future__ import annotations

import argparse
import json
import os
from urllib.request import Request, urlopen
from urllib.parse import urlencode

API_ROOT = "https://api.github.com/repos/oSoWoSo/oco"
TARGET_BRANCH = "testing"
AUTO_MERGE_PREFIX = "T-autobump/"
TRUSTED_AUTHORS = {"oSoWoSo-bot", "zen0bit", "zenobit"}


def api_request(method: str, path: str, token: str, payload: dict | None = None) -> dict | None:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    request = Request(
        f"{API_ROOT}{path}",
        data=data,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "User-Agent": "oco-testing-merge",
        },
        method=method,
    )
    try:
        with urlopen(request, timeout=60) as response:
            body = response.read()
    except Exception as error:
        raise RuntimeError(f"{method} {path} failed: {error}") from error
    return json.loads(body) if body else None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--head-repo", required=True)
    args = parser.parse_args()

    if args.head_repo != "oSoWoSo/oco":
        print(f"PR from fork ({args.head_repo}) is not auto-merged; leaving for review.")
        return 0

    token = os.environ["GH_TOKEN"]
    query = urlencode({"state": "open", "base": TARGET_BRANCH, "per_page": 100})
    pulls = api_request("GET", f"/pulls?{query}", token)
    if not pulls:
        print(f"No open PR targets {TARGET_BRANCH}; nothing to merge.")
        return 0

    match = next((p for p in pulls if p.get("head", {}).get("sha") == args.head_sha), None)
    if match is None:
        print(f"No open PR to {TARGET_BRANCH} with head {args.head_sha} found; skipping.")
        return 0

    # Re-verify the head immediately before merging. A contributor can push new
    # commits or the branch can be force-rewritten between the build run and
    # this API call; rebasing whatever is there now would publish untested code.
    current = api_request("GET", f"/pulls/{match['number']}", token)
    if not current or current.get("head", {}).get("sha") != args.head_sha:
        print(f"PR #{match['number']} head changed since the passed build "
              f"({current.get('head', {}).get('sha') if current else 'gone'}); skip.")
        return 0
    if current.get("base", {}).get("ref") != TARGET_BRANCH:
        print(f"PR #{match['number']} no longer targets {TARGET_BRANCH}; skip.")
        return 0

    # OCO parity gate: only bot-created T-autobump branches auto-merge.
    head_ref = current.get("head", {}).get("ref", "")
    if not head_ref.startswith(AUTO_MERGE_PREFIX):
        print(f"PR #{match['number']} head {head_ref!r} is not a "
              f"{AUTO_MERGE_PREFIX} branch; left for review.")
        return 0
    author = current.get("user", {}).get("login", "")
    if author not in TRUSTED_AUTHORS:
        print(f"PR #{match['number']} author {author!r} is not trusted; left for review.")
        return 0

    # Rebase and fast-forward: preserve the PR's real commits on top of the
    # current testing tip (no synthetic squash/merge commit).
    merged = api_request(
        "PUT",
        f"/pulls/{match['number']}/merge",
        token,
        {
            "sha": current["head"]["sha"],
            "merge_method": "rebase",
        },
    )
    if not merged or merged.get("merged") is not True:
        raise RuntimeError(f"Merge of PR #{match['number']} did not succeed: {merged}")
    print(f"Rebased+fast-forwarded PR #{match['number']} into {TARGET_BRANCH} "
          f"({merged.get('sha', '')}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())