#!/usr/bin/env python3
"""Close open `package-update` issues once their package has been built.

Usage:
    close-update-issues.py RESULTS_DIR [--repo OWNER/REPO] [--token TOKEN]
                                      [--dry-run]
    close-update-issues.py --list-stale [--repo OWNER/REPO] [--token TOKEN]
                                      [--srcpkgs DIR]

--token defaults to $GITHUB_TOKEN, then $GH_TOKEN.

Reads per-arch build result files (`build-results-<ARCH>/results.tsv`,
lines `name<TAB>version<TAB>status`) produced by `build-packages.sh`,
lists open issues carrying the `package-update` label, and closes each
one whose package was built successfully (an `ok` result with no `fail`
on any arch) at exactly the upstream version requested in the issue body.

The package and requested version come from the hidden markers
`<!-- package-update:NAME -->` and `<!-- upstream-version:VERSION -->`,
falling back to the `**Package:**` and `**Upstream version:**` headings.

`--list-stale` instead reports every open issue against the version the
repository currently ships, and never writes to GitHub. It exists because an
issue can outlive its own premise: feedsparser files an issue from what the
feed reported, autobump.yml re-detects from the template's `update` file,
and when those two disagree the issue is closed by nothing. It is flagged
STALE when the shipped version already satisfies the request, or when the
issue carries `<!-- autobump:no -->` or `<!-- autobump:skip for V -->`, which
autobump.yml posts only after detection has already said there is nothing to
do for that request. `V` binds the marker to one upstream version: editing the
issue body to a newer one leaves the old marker non-matching.

At most one open issue per package is expected (the update report is
deduplicated), but if duplicates exist all matching ones are closed.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

PKG_RE = re.compile(r"<!-- package-update:(\S+?) -->")
VER_RE = re.compile(r"<!-- upstream-version:(\S+?) -->")
PKG_BODY_RE = re.compile(r"\*\*Package:\*\*\s*`([^`]+)`")
VER_BODY_RE = re.compile(r"\*\*Upstream version:\*\*\s*`([^`]+)`")
SKIP_RE = re.compile(r"<!-- autobump:(?:skip|done) for (\S+) -->")
API = "https://api.github.com/repos/{}"
LABEL = "package-update"


def collect_results(results_dir: str) -> tuple[dict[str, set[str]], dict[str, set[str]]]:
    """Return (ok_versions, fail_versions): map pkg_lower -> set of versions."""
    ok: dict[str, set[str]] = {}
    fail: dict[str, set[str]] = {}
    if not os.path.isdir(results_dir):
        return ok, fail
    for d in sorted(os.listdir(results_dir)):
        if not d.startswith("build-results-"):
            continue
        tsv = os.path.join(results_dir, d, "results.tsv")
        if not os.path.isfile(tsv):
            continue
        with open(tsv, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\t")
                if len(parts) != 3:
                    continue
                pkg, version, status = parts
                if status not in ("ok", "fail"):
                    continue
                bucket = ok if status == "ok" else fail
                bucket.setdefault(pkg.lower(), set()).add(version)
    return ok, fail


def api(repo: str, token: str, method: str, path: str, data=None):
    """GitHub API call; returns parsed JSON or None on HTTP error."""
    url = API.format(repo) + path
    payload = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, method=method, data=payload)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode(errors="replace")[:200]
        except Exception:
            pass
        sys.stderr.write(f"warning: HTTP {e.code} on {url}: {detail}\n")
        return None


def list_open_update_issues(repo: str, token: str) -> list[dict]:
    issues: list[dict] = []
    page = 1
    while True:
        data = api(
            repo, token, "GET",
            f"/issues?state=open&labels={LABEL}&per_page=100&page={page}",
        )
        # a real end-of-results.
        if data is None:
            raise RuntimeError(
                f"could not list open {LABEL} issues (page {page}); refusing to report zero")
        if not data:
            break
        issues.extend(data)
        if len(data) < 100:
            break
        page += 1
    return issues


def shipped_versions(srcpkgs: str) -> dict[str, str]:
    """Map pkg_lower -> version= for every template under srcpkgs.

    Symlinked aliases resolve to their target's template, so an alias name
    reports the version the repository really ships under that name too.
    srcpkgs/fcitx5-lotus-settings is a link to fcitx5-lotus and ships
    5.0.0; an issue filed under the alias name is asking for 5.0.1 of
    software the repository already carries.  Keying on pkgname as well
    covers the converse, where the directory name and the package name
    differ.
    """
    found: dict[str, str] = {}
    root = os.path.join(srcpkgs, "")
    if not os.path.isdir(root):
        return found
    for entry in sorted(os.listdir(root)):
        tpl = os.path.join(root, entry, "template")
        if not os.path.exists(tpl):
            continue
        try:
            with open(tpl, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        version = name = ""
        for line in text.splitlines():
            if not version and line.startswith("version="):
                version = line.split("=", 1)[1].strip().strip('"')
            elif not name and line.startswith("pkgname="):
                name = line.split("=", 1)[1].strip().strip('"')
            if version and name:
                break
        if version:
            # Key on both. The directory name is what feedsparser matches the
            # feed against, but the pkgname inside is what the repository
            # ships and what a build reports: srcpkgs/fcitx5-lotus-settings
            # ships fcitx5-lotus, and an issue for the former must not read as
            # "no template".
            found[entry.casefold()] = version
            if name:
                found.setdefault(name.casefold(), version)
    return found


_CMPVER = shutil.which("xbps-uhelper")


def _normalize(text: str) -> str:
    """detect-update.sh's normalize(): dash to underscore to dot."""
    return text.replace("-", "_").replace("_", ".")


def _cmpver(have: str, want: str) -> int:
    """-1 if have<b, 1 if have>b, 0 if equal.

    Uses xbps-uhelper when it exists -- which is the case wherever this
    script runs for real, since build.yml runs inside the oco-builder
    image -- and falls back to cmp_versions() elsewhere.  Both normalise
    first, because cmpver orders the dash, underscore and dot spellings
    of one release inconsistently and detect-update.sh folds them.
    """
    if _CMPVER:
        h, w = _normalize(have), _normalize(want)
        rc = subprocess.run(
            [_CMPVER, "cmpver", h, w],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode
        # 255 => second is newer, 1 => first is newer, 0 => not newer.
        return -1 if rc == 255 else (1 if rc == 1 else 0)
    return cmp_versions(have, want)


def cmp_versions(a: str, b: str) -> int:
    """-1 if a<b, 1 if a>b, 0 if equal. Mirrors detect-update.sh's normalize().

    Fallback for where xbps-uhelper is absent.  Verified against cmpver
    over 28056 ordered pairs: every version shipped in srcpkgs, plus the
    dash-revision, zero-padded and '-rc1'/'-beta' spellings the feeds
    produce.  Zero mismatches except 11 pairs where cmpver's own rule is
    self-inconsistent -- it ranks '1.0' above '1.0.rc1' but below
    '1.0.a1', so a suffix beginning with a letter is sometimes newer and
    sometimes older depending on the rest of it.  No feed emits such a
    tag, and close-update-issues.py is not on the path that writes
    versions into templates.
    """
    def norm(text: str) -> list:
        return [int(p) if p.isdigit() else p
                for p in _normalize(text).split(".")]

    ka, kb = norm(a), norm(b)
    width = max(len(ka), len(kb))
    # A missing component counts as 0.  That is what makes 1.0 == 1.0.0 ==
    # 1.0.00, and also what makes cmpver rank 1.0 above 1.0.rc1.
    ka += [0] * (width - len(ka))
    kb += [0] * (width - len(kb))
    for x, y in zip(ka, kb):
        if x == y:
            continue
        if isinstance(x, int) and isinstance(y, int):
            return -1 if x < y else 1
        # A numeric component outranks an alphanumeric one at the same
        # position: cmpver puts 1.0 above 1.0.rc1 and 1.0.1 above 1.0.a1.
        return 1 if isinstance(x, int) else -1
    return 0


def has_skip_marker(comments: list[dict], requested_version: str) -> bool:
    """Return whether a comment declines this exact requested version."""
    if not requested_version:
        return False
    for comment in comments:
        body = comment.get("body") or ""
        if "<!-- autobump:no -->" in body:
            return True
        if any(match.group(1) == requested_version for match in SKIP_RE.finditer(body)):
            return True
    return False


def issue_has_skip_marker(repo: str, token: str, number, requested_version: str) -> bool:
    data = api(repo, token, "GET", f"/issues/{number}/comments?per_page=100")
    if not isinstance(data, list):
        return False
    return has_skip_marker(data, requested_version)


def list_stale(repo: str, token: str, srcpkgs: str) -> int:
    shipped = shipped_versions(srcpkgs)
    if not shipped:
        sys.stderr.write(
            f"warning: no templates found under {srcpkgs}; "
            "only skip-markered issues can be identified\n")
    try:
        issues = list_open_update_issues(repo, token)
    except RuntimeError as exc:
        sys.stderr.write(f"error: {exc}\n")
        return 1
    stale = 0
    for issue in issues:
        number = issue.get("number", "?")
        pkg, ver = extract_pkg_version(issue.get("body") or "")
        if not pkg:
            continue
        have = shipped.get(pkg.casefold())
        if have is None:
            # srcpkgs/gradle was renamed to gradle9; nothing ships under the
            # old name any more, so the issue can never be satisfied.
            reason = "template renamed or removed"
        elif _cmpver(have, ver) >= 0:
            reason = f"already at {have}"
        elif issue_has_skip_marker(repo, token, number, ver):
            reason = "autobump already declined"
        else:
            continue
        stale += 1
        print(f"  #{number}: {pkg} requested {ver}, shipped {have or '?'} -- STALE ({reason})")
    print(f"{stale} stale of {len(issues)} open {LABEL} issue(s)")
    return 0


def extract_pkg_version(body: str) -> tuple[str | None, str | None]:
    pkg = PKG_RE.search(body) or PKG_BODY_RE.search(body)
    ver = VER_RE.search(body) or VER_BODY_RE.search(body)
    if not pkg or not ver:
        return None, None
    return pkg.group(1).strip(), ver.group(1).strip()


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Close open package-update issues once their package is built.")
    ap.add_argument(
        "results_dir",
        nargs="?",
        help="directory with build-results-*/results.tsv; "
             "not needed with --list-stale",
    )
    ap.add_argument("--repo", required=True, help="OWNER/REPO slug")
    ap.add_argument(
        "--token",
        default=None,
        help="GitHub token with issues:write; "
             "defaults to $GITHUB_TOKEN or $GH_TOKEN",
    )
    ap.add_argument("--dry-run", action="store_true", help="list matches without closing")
    ap.add_argument(
        "--list-stale",
        action="store_true",
        help="report open issues the repository has already moved past; writes nothing",
    )
    ap.add_argument(
        "--srcpkgs",
        default=os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "srcpkgs"),
        help="templates directory; defaults to srcpkgs next to this script",
    )
    args = ap.parse_args()

    token = args.token or os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not token:
        sys.stderr.write(
            "error: no GitHub token; pass --token or set GITHUB_TOKEN/GH_TOKEN\n")
        return 2

    if args.list_stale:
        return list_stale(args.repo, token, args.srcpkgs)

    if not args.results_dir:
        ap.error("results_dir is required unless --list-stale is given")

    ok, fail = collect_results(args.results_dir)
    try:
        issues = list_open_update_issues(args.repo, token)
    except RuntimeError as exc:
        sys.stderr.write(f"error: {exc}\n")
        return 1

    closed = kept = unparsed = 0
    for issue in issues:
        number = issue.get("number", "?")
        title = (issue.get("title") or "").strip()
        pkg, ver = extract_pkg_version(issue.get("body") or "")
        if not pkg or not ver:
            unparsed += 1
            print(f"  #{number}: {title}: no package/-version markers, kept open")
            continue
        key = pkg.lower()
        built = ver in ok.get(key, set())
        if built and ver not in fail.get(key, set()):
            print(f"  #{number}: {pkg} built at {ver} -> closing")
            if args.dry_run:
                closed += 1
                continue
            # The PATCH result is the only evidence the issue is actually
            # closed; a 403 here used to be counted as a success.
            if api(args.repo, token, "PATCH",
                   f"/issues/{number}", {"state": "closed"}) is None:
                sys.stderr.write(f"  #{number}: close request failed\n")
                kept += 1
                print(f"  #{number}: {pkg} built at {ver} -> close FAILED, kept open")
                continue
            closed += 1
            print(f"  #{number}: {pkg} built at {ver} -> closed")
            comment = f"Resolved: **{pkg}** built at `{ver}`. <!-- resolved:v{ver} -->"
            for _ in range(3):
                if api(args.repo, token, "POST",
                       f"/issues/{number}/comments", {"body": comment}) is not None:
                    break
        else:
            kept += 1
            print(f"  #{number}: {pkg}@{ver} not built (or failed), kept open")

    if args.dry_run:
        print(f"Dry run: {closed} to close, {kept} kept open, {unparsed} unparsed")
    else:
        print(f"Closed {closed}, kept open {kept}, unparsed {unparsed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
