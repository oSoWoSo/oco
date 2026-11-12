#!/usr/bin/env python3
"""Mirror pull requests and their merge/close state between the two OCO forges."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen

REPOSITORY = "oSoWoSo/oco"
BASE_BRANCH = "OCO"
OPEN_ACTIONS = {"opened", "reopened", "synchronize", "edited"}
CLOSED_ACTIONS = {"closed"}
FORGE_HOSTS = {"github": "github.com", "codeberg": "codeberg.org"}
# Generous read timeout: forge APIs can exceed 30s on slow but successful
# writes, and a false timeout turns a completed mirror into a red check.
REQUEST_TIMEOUT = 60


class ApiRequestTimeoutError(RuntimeError):
    """A request received no response in time; it may still have applied."""


def _is_timeout(error: Exception) -> bool:
    cause: Exception | None = error
    while cause is not None:
        if isinstance(cause, TimeoutError):
            return True
        if isinstance(getattr(cause, "reason", None), TimeoutError):
            return True
        cause = cause.__cause__
    return False


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
        with urlopen(request, timeout=REQUEST_TIMEOUT) as response:
            body = response.read()
    except Exception as error:
        if _is_timeout(error):
            raise ApiRequestTimeoutError(f"{method} {path} timed out: {error}") from error
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

TEMPLATE_LINK_RE = re.compile(
    r"https://(?:github\.com|codeberg\.org)/oSoWoSo/oco/"
    r"(?:blob|src/branch)/(.+?)/srcpkgs/([^/\s)]+)/template"
)


def rewrite_template_links(body: str, target_forge: str, target_branch: str) -> str:
    """Point template links in a PR body at the target PR branch."""
    def replacement(match):
        package = match.group(2)
        if target_forge == "github":
            return (
                f"https://github.com/{REPOSITORY}/blob/"
                f"{target_branch}/srcpkgs/{package}/template"
            )
        return (
            f"https://codeberg.org/{REPOSITORY}/src/branch/"
            f"{target_branch}/srcpkgs/{package}/template"
        )

    return TEMPLATE_LINK_RE.sub(replacement, body)


def _find_mirror(api, target_branch: str, target_forge: str) -> dict | None:
    """Return the existing mirror PR for ``target_branch`` against OCO, if any."""
    owner, _name = REPOSITORY.split("/", 1)
    if target_forge == "codeberg":
        # Forgejo filters PRs by bare branch name; "owner:branch" is
        # GitHub-only syntax and silently matches nothing, which would make
        # every update attempt re-create a PR and hit HTTP 409.
        head_filter = target_branch
    else:
        head_filter = f"{owner}:{target_branch}"
    query = urlencode({
        "state": "all",
        "head": head_filter,
        "base": BASE_BRANCH,
        "limit": 50,
        "per_page": 50,
    })
    pulls = api("GET", f"/pulls?{query}")
    return next(
        (item for item in pulls
         if item.get("head", {}).get("ref") == target_branch
         and item.get("base", {}).get("ref") == BASE_BRANCH),
        None,
    )


def _target_forge(source_forge: str) -> str:
    return "codeberg" if source_forge == "github" else "github"


def _close_mirror(api, target_forge: str, target_number, *, merged: bool, merge_sha: str | None):
    """Reflect a merged/closed source PR on the target forge.

    A merged source records a ``manually-merged`` PR on Forgejo (Codeberg) so
    it shows the merged state without creating a divergent commit. GitHub has
    no manually-merged concept, so the mirror PR is closed with a comment.
    An unmerged close simply closes the mirror PR on either forge.
    """
    if merged is not True:
        return api("PATCH", f"/pulls/{target_number}", {"state": "closed"})

    if target_forge != "codeberg":
        api("PATCH", f"/pulls/{target_number}", {"state": "closed"})
        return api("POST", f"/issues/{target_number}/comments", {
            "body": "This mirrored PR was merged on the source forge; closing it here.",
        })

    # Forgejo only records a manually-merged PR when ``merge_commit_id`` is
    # already reachable in the base branch. The GitHub merge reaches Codeberg
    # OCO through toCB.yml, which races this workflow, so retry briefly and
    # fall back to closing the mirror PR with a comment if the commit has not
    # propagated yet.
    payload = {"do": "manually-merged"}
    if merge_sha:
        payload["merge_commit_id"] = merge_sha
    for attempt in range(3):
        try:
            return api("POST", f"/pulls/{target_number}/merge", payload)
        except (ApiRequestTimeoutError, RuntimeError):
            current = api("GET", f"/pulls/{target_number}")
            if current and (current.get("merged") or current.get("state") == "merged"):
                return current
            if attempt < 2:
                time.sleep(15)
    api("PATCH", f"/pulls/{target_number}", {"state": "closed"})
    return api("POST", f"/issues/{target_number}/comments", {
        "body": "This mirrored PR was merged on the source forge; the commit has "
                "not reached Codeberg OCO yet, so it was closed instead.",
    })


def _apply_closed_state(event, api):
    """Reflect a merged/closed source PR on the mirrored forge.

    Returns the target API response, or None when there is no mirror PR to
    touch.
    """
    pr = event["pull_request"]
    head = pr["head"]
    base = pr["base"]
    if head["ref"].startswith("mirror/"):
        return None
    source_number = int(pr["number"])
    source_forge = event["source_forge"]
    target_forge = _target_forge(source_forge)
    target_branch = f"mirror/{source_forge}/pr-{source_number}"

    existing = _find_mirror(api, target_branch, target_forge)
    if existing is None:
        return None
    target_number = existing.get("number") or existing.get("index")

    merged = bool(pr.get("merged"))
    merge_sha = pr.get("merge_commit_sha") or pr.get("head", {}).get("sha")
    merge_sha = merge_sha if isinstance(merge_sha, str) and merge_sha else None

    return _close_mirror(
        api, target_forge, target_number, merged=merged, merge_sha=merge_sha,
    )


def mirror_pr(event: dict, source_forge: str, api, push_branch):
    """Create or update the matching PR; API and git effects are injected for tests."""
    action = event["action"]
    pr = event["pull_request"]
    head = pr["head"]
    base = pr["base"]
    source_number = int(pr["number"])

    if base["ref"] != BASE_BRANCH:
        return None
    if head["ref"].startswith("mirror/"):
        return None
    if action in CLOSED_ACTIONS:
        return _apply_closed_state({**event, "source_forge": source_forge}, api)

    if action not in OPEN_ACTIONS:
        return None

    target_forge = _target_forge(source_forge)
    target_branch = f"mirror/{source_forge}/pr-{source_number}"
    source_url = pr["html_url"]
    body = (pr.get("body") or "").rstrip()
    body = rewrite_template_links(body, target_forge, target_branch)
    target_body = f"{body}\n\n---\nMirrored from {source_url}" if body else f"Mirrored from {source_url}"
    title = pr["title"]

    push_branch(head["repo"]["clone_url"], head["sha"], target_branch)

    owner, _name = REPOSITORY.split("/", 1)
    payload = {"title": title, "body": target_body}
    if action == "reopened":
        payload["state"] = "open"

    existing = _find_mirror(api, target_branch, target_forge)
    if existing:
        target_number = existing.get("number") or existing.get("index")
        return api("PATCH", f"/pulls/{target_number}", payload)

    payload.update({
        "head": f"{owner}:{target_branch}" if target_forge == "github" else target_branch,
        "base": BASE_BRANCH,
    })
    try:
        return api("POST", "/pulls", payload)
    except ApiRequestTimeoutError as error:
        # The create may have applied before the response timed out. If the
        # mirror PR now exists, treat the mirror as complete; only fail when
        # nothing actually landed.
        created = _find_mirror(api, target_branch, target_forge)
        if created is None:
            raise
        print(f"{error}; confirmed mirror PR already created")
        return created


def codeberg_pull_request(number: str) -> dict:
    request = Request(
        f"https://codeberg.org/api/v1/repos/{REPOSITORY}/pulls/{int(number)}",
        headers={
            "Accept": "application/json",
            "User-Agent": "oco-pr-mirror",
        },
    )
    try:
        with urlopen(request, timeout=REQUEST_TIMEOUT) as response:
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
                "merged": os.environ.get("PR_MERGED", "").lower() == "true",
                "merge_commit_sha": os.environ.get("PR_MERGE_COMMIT_SHA", "") or None,
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
