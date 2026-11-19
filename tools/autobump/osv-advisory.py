#!/usr/bin/env python3
"""Non-blocking, reviewed-identity OSV advisory lookup for autobumps."""

import argparse
import html
import json
import re
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

OSV_QUERY_URL = "https://api.osv.dev/v1/query"
OSV_RECORD_URL = "https://osv.dev/vulnerability/{id}"
# GitHub refuses PR/issue bodies longer than 65536 characters; the OSV
# section shares the body with the package table and build order.
DEFAULT_MAX_CHARS = 20000


def markdown_text(value: object) -> str:
    """Render untrusted text as inert Markdown text/code content."""
    text = html.escape(str(value), quote=True)
    return re.sub(r"([\\`*_{}\[\]()#+.!|>~-])", r"\\\1", text)


def load_identity(mapping_path: Path, package: str, version: str, include_version=True):
    data = json.loads(mapping_path.read_text(encoding="utf-8"))
    packages = data.get("packages", {})
    if not isinstance(packages, dict):
        raise ValueError('mapping "packages" must be an object')
    entry = packages.get(package)
    if entry is None:
        return None
    if not isinstance(entry, dict):
        raise ValueError(f"identity for {package} must be an object")

    kind = entry.get("type")
    if kind == "package":
        ecosystem, name = entry.get("ecosystem"), entry.get("name")
        if not isinstance(ecosystem, str) or not ecosystem.strip() or not isinstance(name, str) or not name.strip():
            raise ValueError(f"{package}: package identity requires ecosystem and name")
        identity = {"package": {"ecosystem": ecosystem, "name": name}}
        if include_version:
            identity["version"] = version
        return identity
    if kind == "git":
        repo, tag_template = entry.get("repo"), entry.get("version_tag")
        if not isinstance(repo, str) or not repo.strip() or not isinstance(tag_template, str):
            raise ValueError(f"{package}: GIT identity requires repo and reviewed version_tag")
        if tag_template.count("{version}") != 1 or re.sub(r"\{version\}", "", tag_template).find("{") >= 0 or re.sub(r"\{version\}", "", tag_template).find("}") >= 0:
            raise ValueError(f"{package}: version_tag must contain exactly one {{version}} placeholder and no other braces")
        identity = {"package": {"ecosystem": "GIT", "name": repo}}
        if include_version:
            identity["version"] = tag_template.replace("{version}", version)
        return identity
    raise ValueError(f"{package}: identity type must be package or git")


def query_osv(query: dict, opener=urlopen):
    vulns = []
    page_token = None
    seen_tokens = set()
    while True:
        page_query = dict(query)
        if page_token is not None:
            page_query["page_token"] = page_token
        request = Request(
            OSV_QUERY_URL,
            data=json.dumps(page_query, sort_keys=True).encode("utf-8"),
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            method="POST",
        )
        with opener(request, timeout=15) as response:
            result = json.loads(response.read().decode("utf-8"))
        if not isinstance(result, dict):
            raise ValueError("OSV response is not an object")
        page_vulns = result.get("vulns", [])
        if not isinstance(page_vulns, list):
            raise ValueError("OSV response field 'vulns' is not a list")
        vulns.extend(page_vulns)

        next_token = result.get("next_page_token")
        if next_token is None:
            break
        if not isinstance(next_token, str) or not next_token:
            raise ValueError("OSV response field 'next_page_token' is not a non-empty string")
        if next_token in seen_tokens:
            raise ValueError("OSV pagination returned a repeated page token")
        seen_tokens.add(next_token)
        page_token = next_token
    return {"vulns": vulns}


def affected_details(item) -> str:
    """Render compact range boundaries; the explicit version list is skipped.

    OSV advisories for large projects (e.g. llama.cpp) enumerate thousands of
    versions, which would blow past GitHub's PR body size limit. The range
    boundaries (introduced/fixed/last_affected) plus the record link carry the
    same signal in a few characters; the full list stays one click away.
    """
    affected = item.get("affected", [])
    if not isinstance(affected, list):
        return ""
    details = []
    for entry in affected:
        if not isinstance(entry, dict):
            continue
        ranges = entry.get("ranges", [])
        if not isinstance(ranges, list):
            continue
        parts = []
        for range_entry in ranges:
            if not isinstance(range_entry, dict):
                continue
            range_type = markdown_text(range_entry.get("type", "range"))
            events = range_entry.get("events", [])
            boundaries = []
            if isinstance(events, list):
                for event in events:
                    if isinstance(event, dict):
                        boundaries.extend(
                            f"{markdown_text(kind)} {markdown_text(value)}"
                            for kind, value in event.items()
                        )
            if boundaries:
                parts.append(f"{range_type}: " + "; ".join(boundaries))
        if parts:
            details.append("; ".join(parts))
    return "Affected: " + " | ".join(details) if details else ""


def advisory_link(identifier: str) -> str:
    """Inert link to the full osv.dev record for an advisory."""
    return f"[{markdown_text(identifier)}]({OSV_RECORD_URL.format(id=quote(identifier))})"


def advisory_status(item) -> str:
    """Classify advisories by whether OSV records a fixed range boundary."""
    affected = item.get("affected", [])
    if isinstance(affected, list):
        for entry in affected:
            if not isinstance(entry, dict):
                continue
            ranges = entry.get("ranges", [])
            if not isinstance(ranges, list):
                continue
            for range_entry in ranges:
                if not isinstance(range_entry, dict):
                    continue
                events = range_entry.get("events", [])
                if isinstance(events, list) and any(
                    isinstance(event, dict) and event.get("fixed")
                    for event in events
                ):
                    return "🟢 **FIXED**"
    return "🔴 **OPEN**"


def _cap_length(report: str, package: str, version: str, max_chars: int) -> str:
    """Trim a report that would overflow the PR body, keeping the tray tail."""
    if max_chars and len(report) > max_chars:
        shown = report[:max_chars].rstrip() + "\n"
        note = (f"\n_(Report truncated: the full **{markdown_text(package)} "
                f"{markdown_text(version)}** OSV listing is available per-advisory "
                "via the record links above.)_\n")
        return shown + note
    return report


def make_report(package: str, version: str, status: str, findings=None, error=None,
                all_upstream=False, max_chars=DEFAULT_MAX_CHARS) -> str:
    title = f"OSV advisory check: {markdown_text(package)} {markdown_text(version)}"
    scope = ("Scope: **all upstream advisories** for the reviewed package identity; "
             "the displayed bumped version is contextual only.\n\n" if all_upstream else "")
    if status == "unmapped":
        body = "No OSV identity is configured; this is **not** a clean bill of health."
    elif status == "no_matches":
        body = ("No OSV advisories were returned for the reviewed upstream identity."
                if all_upstream else
                "No matching OSV advisories were returned for the reviewed identity/version.")
    elif status == "error":
        body = f"**ERROR:** OSV lookup could not be completed: {markdown_text(error or 'unknown error')}"
    else:
        rows = []
        for item in sorted(findings or [], key=lambda row: str(row.get("id", ""))):
            identifier = str(item.get("id", "(missing ID)"))
            summary = markdown_text(item.get("summary") or "No summary provided.")
            aliases = sorted(str(alias) for alias in item.get("aliases", []) if alias)
            ids = [advisory_link(identifier)] + [advisory_link(alias) for alias in aliases]
            label = " — **WITHDRAWN**" if item.get("withdrawn") else ""
            affected = affected_details(item)
            detail = f"\n  {affected}" if affected else ""
            rows.append(f"- {advisory_status(item)} — **{'**, **'.join(ids)}**{label} — {summary}{detail}")
        body = "Advisories (informational; this does not block autobump):\n\n" + "\n".join(rows)
    return _cap_length(f"### {title}\n\n{scope}{body}\n", package, version, max_chars)


def check(mapping_path: Path, package: str, version: str, opener=urlopen,
          all_upstream=False, max_chars=DEFAULT_MAX_CHARS) -> str:
    try:
        query = load_identity(mapping_path, package, version, include_version=not all_upstream)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return make_report(package, version, "error", error=f"invalid identity mapping: {exc}",
                           all_upstream=all_upstream, max_chars=max_chars)
    if query is None:
        return make_report(package, version, "unmapped", all_upstream=all_upstream,
                           max_chars=max_chars)
    try:
        result = query_osv(query, opener=opener)
        vulns = result.get("vulns", [])
        if not isinstance(vulns, list):
            raise ValueError("OSV response field 'vulns' is not a list")
        return make_report(package, version, "findings" if vulns else "no_matches", vulns,
                           all_upstream=all_upstream, max_chars=max_chars)
    except (HTTPError, URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError) as exc:
        return make_report(package, version, "error", error=str(exc),
                           all_upstream=all_upstream, max_chars=max_chars)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package")
    parser.add_argument("version")
    parser.add_argument("--mapping", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--all-upstream", action="store_true",
                        help="report all advisories for the reviewed upstream identity, regardless of version")
    parser.add_argument("--max-chars", type=int, default=DEFAULT_MAX_CHARS,
                        help="cap the report length so the autobump PR body stays "
                             "under GitHub's limit (default: %(default)s)")
    args = parser.parse_args()
    report = check(args.mapping, args.package, args.version, all_upstream=args.all_upstream,
                   max_chars=args.max_chars)
    if args.output:
        args.output.write_text(report, encoding="utf-8")
    else:
        sys.stdout.write(report)
    # Lookup problems are advisory data, not autobump failures; the report labels them.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
