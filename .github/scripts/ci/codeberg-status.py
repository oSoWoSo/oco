#!/usr/bin/env python3
"""Report a GitHub Actions check result to a Codeberg/Forgejo PR head."""

from __future__ import annotations

import json
import os
import re
from urllib.error import HTTPError
from urllib.request import Request, urlopen

REPOSITORY = "oSoWoSo/oco"
API_ROOT = f"https://codeberg.org/api/v1/repos/{REPOSITORY}"


class CommitUnavailableError(RuntimeError):
    """The target commit is not reachable on Codeberg (PR closed/updated)."""


def post_status(token: str, sha: str, state: str, description: str, target_url: str) -> None:
    """Create a commit status on the Codeberg commit ``sha``."""
    if state not in {"pending", "success", "failure", "error"}:
        raise ValueError(f"unsupported status state: {state}")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError(f"unexpected commit SHA: {sha!r}")

    payload = {
        "state": state,
        "context": "ci/github",
        "description": description[:140],
        "target_url": target_url,
    }
    request = Request(
        f"{API_ROOT}/statuses/{sha}",
        data=json.dumps(payload).encode(),
        method="POST",
        headers={
            "accept": "application/json",
            "authorization": f"token {token}",
            "content-type": "application/json",
            "user-agent": "oco-status-back",
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            return json.loads(response.read())
    except HTTPError as error:
        if error.code == 404:
            # The Codeberg PR head moved (force-push/close) and the commit we
            # built is no longer reachable; there is nothing to attach the
            # status to. Treat it as a no-op rather than failing the run.
            raise CommitUnavailableError(
                f"commit {sha} is not reachable on Codeberg (PR updated/closed)"
            ) from error
        raise RuntimeError(
            f"Codeberg status API returned {error.code}: {error.read().decode()[:500]}"
        ) from error


def main() -> int:
    token = os.environ["CODEBERG_TOKEN"]
    sha = os.environ["COMMIT_SHA"]
    state = os.environ["STATUS_STATE"]
    description = os.environ.get("STATUS_DESCRIPTION", "GitHub Actions check")
    target_url = os.environ.get("TARGET_URL", "")
    try:
        data = post_status(token, sha, state, description, target_url)
    except CommitUnavailableError as error:
        print(f"Skipped: {error}")
        return 0
    print(f"Reported {state} for {sha[:12]} -> {data.get('url', data)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())