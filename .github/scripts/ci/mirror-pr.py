#!/usr/bin/env python3
"""Mirror an open pull request to the other OCO forge."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen

REPOSITORY = "oSoWoSo/oco"
BASE_BRANCH = "OCO"
SUPPORTED_ACTIONS = {"opened", "reopened", "synchronize", "edited"}
FORGE_HOSTS = {"github": "github.com", "codeberg": "codeberg.org"}


def api_request(method: str, path: str, token: str, payload: dict | None = None):
    url = f"{os.environ['TARGET_API_ROOT'].rstrip('/')}{path}"
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    request = Request(
        url,
        data=data,
        method=method,
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "User-Agent": "oco-pr-mirror",
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            body = response.read()
    except Exception as error:
        raise RuntimeError(f"{method} {path} failed: {error}") from error
    return json.loads(body) if body else None


def validate_source_url(source: str, source_forge: str) -> None:
    parsed = urlparse(source)
    if (
        parsed.scheme != "https"
        or parsed.hostname != FORGE_HOSTS[source_forge]
        or parsed.username is not None
        or parsed.password is not None
        or not parsed.path.strip("/").endswith(".git")
    ):
        raise ValueError(f"Refusing unexpected {source_forge} source repository URL")


def push_source_branch(
    source_url: str,
    commit: str,
    target_url: str,
    branch: str,
    token: str,
    username: str,
    source_forge: str,
) -> None:
    validate_source_url(source_url, source_forge)
    if not re.fullmatch(r"[0-9a-fA-F]{40,64}", commit):
        raise ValueError("PR head SHA must be a full commit ID")

    with tempfile.TemporaryDirectory(prefix="oco-pr-mirror-") as directory:
        repo = Path(directory)
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(
            ["git", "-C", str(repo), "fetch", "--no-tags", source_url, commit],
            check=True,
        )
        subprocess.run(["git", "-C", str(repo), "checkout", "-q", "FETCH_HEAD"], check=True)

        askpass = repo / "git-askpass"
        askpass.write_text(
            "#!/bin/sh\n"
            "case \"$1\" in\n"
            "  *Username*) printf '%s\\n' \"$GIT_USERNAME\" ;;\n"
            "  *Password*) printf '%s\\n' \"$GIT_TOKEN\" ;;\n"
            "  *) exit 1 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        askpass.chmod(0o700)
        environment = os.environ.copy()
        environment.update(
            GIT_ASKPASS=str(askpass),
            GIT_TERMINAL_PROMPT="0",
            GIT_USERNAME=username,
            GIT_TOKEN=token,
        )
        subprocess.run(
            [
                "git", "-C", str(repo), "push", "--force", target_url,
                f"HEAD:refs/heads/{branch}",
            ],
            check=True,
            env=environment,
        )


def mirror_pr(event: dict, source_forge: str, api, push_branch):
    """Create or update the matching PR; API and git effects are injected for tests."""
    action = event["action"]
    pr = event["pull_request"]
    head = pr["head"]
    base = pr["base"]
    source_number = int(pr["number"])

    if action not in SUPPORTED_ACTIONS or base["ref"] != BASE_BRANCH:
        return None
    if head["ref"].startswith("mirror/"):
        return None

    target_forge = "codeberg" if source_forge == "github" else "github"
    target_branch = f"mirror/{source_forge}/pr-{source_number}"
    source_url = pr["html_url"]
    body = (pr.get("body") or "").rstrip()
    target_body = f"{body}\n\n---\nMirrored from {source_url}" if body else f"Mirrored from {source_url}"
    title = pr["title"]

    push_branch(head["repo"]["clone_url"], head["sha"], target_branch)

    owner, _name = REPOSITORY.split("/", 1)
    query = urlencode({
        "state": "all",
        "head": f"{owner}:{target_branch}",
        "base": BASE_BRANCH,
        "limit": 50,
        "per_page": 50,
    })
    pulls = api("GET", f"/pulls?{query}")
    existing = next(
        (item for item in pulls
         if item.get("head", {}).get("ref") == target_branch
         and item.get("base", {}).get("ref") == BASE_BRANCH),
        None,
    )
    payload = {"title": title, "body": target_body}
    if action == "reopened":
        payload["state"] = "open"

    if existing:
        target_number = existing.get("number") or existing.get("index")
        return api("PATCH", f"/pulls/{target_number}", payload)

    payload.update({
        "head": f"{owner}:{target_branch}" if target_forge == "github" else target_branch,
        "base": BASE_BRANCH,
    })
    return api("POST", "/pulls", payload)


def codeberg_pull_request(number: str) -> dict:
    request = Request(
        f"https://codeberg.org/api/v1/repos/{REPOSITORY}/pulls/{int(number)}",
        headers={
            "Accept": "application/json",
            "User-Agent": "oco-pr-mirror",
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            return json.loads(response.read())
    except Exception as error:
        raise RuntimeError(f"Could not read Codeberg PR #{number}: {error}") from error


def main() -> int:
    source_forge = os.environ["SOURCE_FORGE"]
    if source_forge not in FORGE_HOSTS:
        raise ValueError("SOURCE_FORGE must be github or codeberg")

    action = os.environ["EVENT_ACTION"]
    if source_forge == "codeberg":
        event = {
            "action": action,
            "pull_request": codeberg_pull_request(os.environ["PR_NUMBER"]),
        }
    else:
        event = {
            "action": action,
            "pull_request": {
                "number": os.environ["PR_NUMBER"],
                "title": os.environ["PR_TITLE"],
                "body": os.environ.get("PR_BODY", ""),
                "html_url": os.environ["PR_URL"],
                "head": {
                    "ref": os.environ["PR_HEAD_REF"],
                    "sha": os.environ["PR_HEAD_SHA"],
                    "repo": {"clone_url": os.environ["PR_HEAD_REPO_URL"]},
                },
                "base": {"ref": os.environ["PR_BASE_REF"]},
            },
        }

    token = os.environ["TARGET_TOKEN"]
    api = lambda method, path, payload=None: api_request(method, path, token, payload)

    def push(source_url: str, commit: str, branch: str) -> None:
        push_source_branch(
            source_url,
            commit,
            os.environ["TARGET_GIT_URL"],
            branch,
            token,
            os.environ["TARGET_GIT_USERNAME"],
            source_forge,
        )

    result = mirror_pr(event, source_forge, api, push)
    if result is None:
        print("PR event is outside the mirror scope; no changes made.")
    else:
        print(f"Mirrored PR to {result.get('html_url', 'target forge')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
