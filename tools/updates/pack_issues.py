"""Publish one update issue per pack, shared by the feed and direct scan."""

from collections import defaultdict
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "autobump"))
from autobump_packs import load_packs, pack_for

PACK_RE = re.compile(r"^<!-- pack-update:([A-Za-z0-9][A-Za-z0-9+._-]*) -->$", re.M)
MEMBER_RE = re.compile(
    r"^<!-- pack-member:([A-Za-z0-9][A-Za-z0-9+._-]*) ([A-Za-z0-9][A-Za-z0-9._+~-]*) -->$",
    re.M,
)


def version_key(text):
    """Sort key with the same semantics detect-update.sh applies."""
    tokens = re.split(r"([.\-_+~]+)", text.strip().lstrip("vV"))
    key = []
    rank = 0
    for index, token in enumerate(tokens):
        if index % 2:
            rank = int("~" in token)
        elif token:
            key.append((1, int(token), rank) if token.isdigit() else (0, 0, token))
            rank = 0
    while key and key[-1] == (1, 0, 0):
        key.pop()
    return key


def record_update(requests, package, version):
    if package not in requests or version_key(version) > version_key(requests[package]):
        requests[package] = version


def pack_members(body):
    return dict(MEMBER_RE.findall(body or ""))


def publish_pack_issues(repo, label, updates, issues, run_gh, *, dry_run=False):
    """Merge detections into open pack issues without dropping other requests."""
    for pack, requests in sorted(updates.items()):
        marker = f"<!-- pack-update:{pack} -->"
        tracked = [issue for issue in issues if marker in (issue.get("body") or "").splitlines()]
        active = next((issue for issue in tracked if issue["state"] == "OPEN"), None)
        previous = pack_members(active["body"]) if active else {}
        seen = previous.copy()
        for issue in tracked:
            if issue["state"] == "CLOSED":
                for pkg, ver in pack_members(issue["body"]).items():
                    record_update(seen, pkg, ver)
        latest = previous.copy()
        for pkg, ver in requests.items():
            if pkg not in seen or version_key(ver) > version_key(seen[pkg]):
                latest[pkg] = ver
        if latest == previous:
            continue

        lines = [marker, "", "| Package | Upstream version |", "|---|---|"]
        for pkg, ver in sorted(latest.items()):
            lines.append(f"| [`{pkg}`](https://github.com/{repo}/blob/OCO/srcpkgs/{pkg}/template) | `{ver}` |")
        lines.extend(["", "Autobump batches these updates. Comment `nobump` to dismiss the pack.", ""])
        lines.extend(f"<!-- pack-member:{pkg} {ver} -->" for pkg, ver in sorted(latest.items()))
        body = "\n".join(lines)
        print(f"{'Would update' if dry_run else 'Updating'} {pack} issue: {len(latest)} package(s)",
              file=sys.stderr)
        if dry_run:
            continue
        if active:
            run_gh(["api", f"repos/{repo}/issues/{active['number']}", "--method", "PATCH",
                    "-f", f"title={pack}", "-f", f"body={body}"])
        else:
            url = run_gh(["issue", "create", "--repo", repo, "--title", pack, "--body", body]).strip()
            # Label after creation so the bumper receives a labeled event with the full request.
            run_gh(["issue", "edit", url, "--repo", repo, "--add-label", label])


def scan_issues(found, repo):
    """File pack issues, passing the remaining scan rows back to the scan script."""
    packs = load_packs(Path.cwd())
    blacklist = set(Path("config/autobump-blacklist").read_text().splitlines())
    updates = defaultdict(dict)
    for row in Path(found).read_text().splitlines():
        pkg, _old, new = row.split()
        pack = pack_for(pkg, packs)
        if pack and pkg not in blacklist:
            record_update(updates[pack], pkg, new)
        else:
            print(row)
    if not updates:
        return

    def run_gh(args):
        return subprocess.check_output(["gh", *args], text=True)

    issues = json.loads(run_gh(["issue", "list", "--repo", repo, "--state", "all", "--limit", "1000",
                                "--json", "number,body,state"]))
    publish_pack_issues(repo, "package-update", updates, issues, run_gh)


if __name__ == "__main__":
    scan_issues(sys.argv[1], os.environ["GITHUB_REPOSITORY"])
