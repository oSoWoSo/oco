#!/usr/bin/env python3
"""Non-blocking, reviewed-identity OSV advisory lookup for autobumps."""

import argparse
import html
import json
import re
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

OSV_QUERY_URL = "https://api.osv.dev/v1/query"


def markdown_text(value: object) -> str:
    """Render untrusted text as inert Markdown text/code content."""
    text = html.escape(str(value), quote=True)
    return re.sub(r"([\\`*_{}\[\]()#+.!|>~-])", r"\\\1", text)


def load_identity(mapping_path: Path, package: str, version: str):
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
        return {"package": {"ecosystem": ecosystem, "name": name}, "version": version}
    if kind == "git":
        repo, tag_template = entry.get("repo"), entry.get("version_tag")
        if not isinstance(repo, str) or not repo.strip() or not isinstance(tag_template, str):
            raise ValueError(f"{package}: GIT identity requires repo and reviewed version_tag")
        if tag_template.count("{version}") != 1 or re.sub(r"\{version\}", "", tag_template).find("{") >= 0 or re.sub(r"\{version\}", "", tag_template).find("}") >= 0:
            raise ValueError(f"{package}: version_tag must contain exactly one {{version}} placeholder and no other braces")
        tag = tag_template.replace("{version}", version)
        return {"package": {"ecosystem": "GIT", "name": repo}, "version": tag}
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


def make_report(package: str, version: str, status: str, findings=None, error=None) -> str:
    title = f"OSV advisory check: {markdown_text(package)} {markdown_text(version)}"
    if status == "unmapped":
        body = "No OSV identity is configured; this is **not** a clean bill of health."
    elif status == "no_matches":
        body = "No matching OSV advisories were returned for the reviewed identity/version."
    elif status == "error":
        body = f"**ERROR:** OSV lookup could not be completed: {markdown_text(error or 'unknown error')}"
    else:
        rows = []
        for item in sorted(findings or [], key=lambda row: str(row.get("id", ""))):
            identifier = markdown_text(item.get("id", "(missing ID)"))
            summary = markdown_text(item.get("summary") or "No summary provided.")
            aliases = sorted(str(alias) for alias in item.get("aliases", []) if alias)
            ids = [identifier] + [markdown_text(alias) for alias in aliases]
            rows.append(f"- **{'**, **'.join(ids)}** — {summary}")
        body = "Matching advisories (informational; this does not block autobump):\n\n" + "\n".join(rows)
    return f"### {title}\n\n{body}\n"


def check(mapping_path: Path, package: str, version: str, opener=urlopen) -> str:
    try:
        query = load_identity(mapping_path, package, version)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return make_report(package, version, "error", error=f"invalid identity mapping: {exc}")
    if query is None:
        return make_report(package, version, "unmapped")
    try:
        result = query_osv(query, opener=opener)
        vulns = result.get("vulns", [])
        if not isinstance(vulns, list):
            raise ValueError("OSV response field 'vulns' is not a list")
        return make_report(package, version, "findings" if vulns else "no_matches", vulns)
    except (HTTPError, URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError) as exc:
        return make_report(package, version, "error", error=str(exc))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package")
    parser.add_argument("version")
    parser.add_argument("--mapping", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = check(args.mapping, args.package, args.version)
    if args.output:
        args.output.write_text(report, encoding="utf-8")
    else:
        sys.stdout.write(report)
    # Lookup problems are advisory data, not autobump failures; the report labels them.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
