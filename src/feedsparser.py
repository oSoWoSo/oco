#!/usr/bin/env python3
"""File `package-update` issues from `src/feed.opml` against OCO templates.

Every feed that resolves to a template opens (or updates) a
`package-update` issue when the upstream feed reports a newer version
than the template ships, and closes it once the repository catches up.

Issues carry version markers that the autobump workflow keys off:
    `<!-- package-update:NAME -->`       identifies the template
    `<!-- upstream-version:VERSION -->`  the upstream version requested
    `<!-- autobump:no -->`               marks templates excluded from
                                         the automated bump (`src/autobump-
                                         blacklist` or symlink aliases);
                                         autobump.yml then treats the
                                         issue as a head-up only.

Open issues are repaired in place: when a stale `autobump:no` marker no
longer matches the template's current eligibility the body is rewritten,
which re-triggers autobump.yml on its `edited` event.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import feedparser


FOLDER_NAME = "package-update"

HERE = Path(__file__).resolve().parent

OPML_PATH = Path(
    os.environ.get(
        "OPML_PATH",
        HERE.parent / "src" / "feed.opml",
    )
)

OCO_DIR = Path(
    os.environ.get("OCO_DIR")
    or HERE.parent
)

DRY_RUN = os.environ.get(
    "DRY_RUN",
    "",
).strip().lower() in (
    "1",
    "true",
    "yes",
)

SRC_PKGS = OCO_DIR / "srcpkgs"

AUTOBUMP_BLACKLIST = (
    Path(os.environ["AUTOBUMP_BLACKLIST"])
    if os.environ.get("AUTOBUMP_BLACKLIST")
    else OCO_DIR / "src" / "autobump-blacklist"
)

TARGET_REPO = os.environ.get(
    "TARGET_REPO",
    "oSoWoSo/oco",
)
ISSUE_LABEL = os.environ.get(
    "OCO_LABEL",
    "package-update",
)

# Per-forge credentials for feed fetching.
HOST_AUTH = (
    (
        (
            "github.com",
            "raw.githubusercontent.com",
            "api.github.com",
        ),
        ("GITHUB_TOKEN", "GH_TOKEN"),
        "Authorization",
        "Bearer {token}",
    ),
    (
        ("codeberg.org",),
        ("CODEBERG_TOKEN",),
        "Authorization",
        "token {token}",
    ),
    (
        ("gitlab.com", "gitlab.freedesktop.org"),
        ("GITLAB_TOKEN",),
        "PRIVATE-TOKEN",
        "{token}",
    ),
)

DEFAULT_HEADERS = {
    "User-Agent": "package-update-github-action/1.0",
}


def auth_headers(url):
    """Return the Authorization-style header for `url`, if we hold a token
    for that forge. Empty dict means "fetch anonymously"."""
    host = urllib.parse.urlparse(url).hostname or ""

    for domains, env_names, header, template in HOST_AUTH:
        for domain in domains:
            if host != domain and not host.endswith("." + domain):
                continue

            for env_name in env_names:
                token = os.environ.get(env_name, "").strip()
                if token:
                    return {header: template.format(token=token)}
            return {}
    return {}
PACKAGES_BY_NAME = {}


VERSION_RE = re.compile(
    r"(?<![0-9])"
    r"v?"
    r"(\d+(?:\.\d+){0,5}"
    r"(?:[-+._][0-9A-Za-z.-]+)?)"
)

SEPARATOR_RANK = {
    ".": 0,
    "_": 0,
    "+": 0,
    "-": 0,
    "~": 1,
}


def log(state, name, detail=""):
    print(f"{state:<8} {name:<26} {detail}".rstrip())


def run_gh(args):
    result = subprocess.run(
        ["gh", *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    if result.returncode != 0:
        print(
            result.stderr,
            file=sys.stderr,
        )

        raise RuntimeError(
            "gh command failed: "
            f"gh {' '.join(args)}"
        )

    return result.stdout


def version_key(text):
    """Sort key with the same semantics detect-update.sh applies.
    """

    tokens = re.split(
        r"([.\-_+~]+)",
        text.strip().lstrip("vV"),
    )

    key = []
    rank = 0

    for index, token in enumerate(tokens):
        if index % 2:
            rank = max(
                SEPARATOR_RANK[separator]
                for separator in token
            )
            continue

        if not token:
            continue

        if token.isdigit():
            key.append((1, int(token), rank))
        else:
            key.append((0, 0, token))

        rank = 0

    # 1.0 == 1.0.0 for xbps.
    while key and key[-1] == (1, 0, 0):
        key.pop()

    return key


class XbpsVersion:
    """Comparable version string using xbps ordering."""

    __slots__ = ("text", "key")

    def __init__(self, text):
        self.text = text
        self.key = version_key(text)

    def __eq__(self, other):
        return self.key == other.key

    def __lt__(self, other):
        return self.key < other.key

    def __le__(self, other):
        return self.key <= other.key

    def __gt__(self, other):
        return self.key > other.key

    def __ge__(self, other):
        return self.key >= other.key

    def __hash__(self):
        return hash(self.text)

    def __str__(self):
        return self.text

    def __repr__(self):
        return (
            f"XbpsVersion({self.text!r})"
        )


def extract_version(text):
    if not text:
        return None

    match = VERSION_RE.search(text)

    if not match:
        return None

    raw = match.group(1)

    return XbpsVersion(raw)


def parse_rules(value):
    rules = []

    if not value:
        return rules

    for line in value.splitlines():
        line = line.strip()

        if not line:
            continue

        if line.startswith("EntryTitle="):
            line = line[len("EntryTitle="):]

        try:
            rules.append(
                re.compile(line)
            )
        except re.error as exc:
            print(
                f"WARNING: invalid rule "
                f"{line!r}: {exc}",
                file=sys.stderr,
            )

    return rules


def get_outline_attribute(outline, name):
    for key, value in outline.attrib.items():
        if key.rsplit("}", 1)[-1] == name:
            return value

    return ""


def entry_allowed(
    title,
    keep_rules,
    block_rules,
):
    if keep_rules:
        if not any(
            rule.search(title)
            for rule in keep_rules
        ):
            return False

    if any(
        rule.search(title)
        for rule in block_rules
    ):
        return False

    return True


def load_opml():
    if not OPML_PATH.is_file():
        raise RuntimeError(
            f"OPML file not found: {OPML_PATH}"
        )

    return ET.parse(
        OPML_PATH
    ).getroot()


def load_feeds():
    root = load_opml()
    body = root.find("body")

    if body is None:
        raise RuntimeError(
            "OPML has no <body>"
        )

    package_folder = None

    for outline in body:
        if not outline.tag.endswith("outline"):
            continue

        if (
            outline.attrib.get("text")
            == FOLDER_NAME
        ):
            package_folder = outline
            break

    if package_folder is None:
        raise RuntimeError(
            f"OPML folder "
            f"{FOLDER_NAME!r} not found"
        )

    feeds = []

    for outline in package_folder:
        if not outline.tag.endswith("outline"):
            continue

        xml_url = outline.attrib.get(
            "xmlUrl",
            "",
        ).strip()

        if not xml_url:
            continue

        html_url = outline.attrib.get(
            "htmlUrl",
            "",
        ).strip()

        name = (
            outline.attrib.get("title")
            or outline.attrib.get("text")
            or ""
        ).strip()

        if not name:
            continue

        block_rules = []

        block_rules.extend(
            parse_rules(
                get_outline_attribute(
                    outline,
                    "blocklistRules",
                )
            )
        )

        block_rules.extend(
            parse_rules(
                get_outline_attribute(
                    outline,
                    "blockFilterEntryRules",
                )
            )
        )

        keep_rules = parse_rules(
            get_outline_attribute(
                outline,
                "keeplistRules",
            )
        )

        keep_rules.extend(
            parse_rules(
                get_outline_attribute(
                    outline,
                    "keepFilterEntryRules",
                )
            )
        )

        feeds.append(
            {
                "name": name,
                "xml_url": xml_url,
                "html_url": html_url,
                "keep_rules": keep_rules,
                "block_rules": block_rules,
            }
        )

    return feeds


def normalize_url(url):
    if not url:
        return ""

    parsed = urllib.parse.urlparse(url)

    host = parsed.netloc.lower()

    if host.startswith("www."):
        host = host[4:]

    path = parsed.path.rstrip("/")

    # Remove common repository/feed suffixes.
    suffixes = (
        "/tags.atom",
        "/releases.atom",
        "/feed.atom",
        "/atom.xml",
        "/rss.xml",
        "/feed.xml",
        "/releases",
        "/tags",
    )

    changed = True

    while changed:
        changed = False

        for suffix in suffixes:
            if path.endswith(suffix):
                path = path[:-len(suffix)].rstrip("/")
                changed = True
                break

    if path.endswith(".git"):
        path = path[:-4]

    return f"{host}{path}".lower()


def url_matches(
    feed_url,
    template_url,
):
    feed = normalize_url(feed_url)
    template = normalize_url(template_url)

    if not feed or not template:
        return False

    if feed == template:
        return True

    # This handles release/archive URLs:
    #
    # github.com/foo/bar
    # github.com/foo/bar/releases/download/...
    #
    # and similar layouts on Codeberg/GitLab.
    if template.startswith(feed + "/"):
        return True

    if feed.startswith(template + "/"):
        return True

    return False


def template_urls(template):
    text = template.read_text(
        encoding="utf-8",
        errors="replace",
    )

    return re.findall(
        r'https?://[^\s"\']+',
        text,
    )


def build_package_map():
    """
    Map every upstream repository to all OCO
    packages using that upstream.


    This is what allows:

        brave-browser
            -> brave-browser-bin
            -> brave-origin-bin


    Also records all package names so feeds whose
    name matches a template can be resolved even
    when their URLs don't line up.


    """
    global PACKAGES_BY_NAME
    mapping = {}
    packages_by_name = {}

    if not SRC_PKGS.is_dir():
        raise RuntimeError(
            f"{SRC_PKGS} does not exist"
        )

    for package_dir in sorted(SRC_PKGS.iterdir()):
        if package_dir.is_symlink():
            continue

        if not package_dir.is_dir():
            continue

        template = (
            package_dir / "template"
        )

        if not template.is_file():
            continue

        package = package_dir.name
        packages_by_name.setdefault(
            package.casefold(),
            package,
        )

        urls = template_urls(template)

        if not urls:
            continue

        for url in urls:
            key = normalize_url(url)

            if not key:
                continue

            mapping.setdefault(
                key,
                set(),
            ).add(package)

    PACKAGES_BY_NAME = packages_by_name

    return mapping


def find_packages_for_feed(
    feed,
    package_map,
):
    """
    Resolve a feed to OCO packages.


    URL matching first (a template can map one
    upstream to several packages, e.g. brave-browser).,
    then fall back to an exact case-insensitive name
    match so feeds whose title equals a template name
    are found even when the URLs don't line up.


    """
    packages = set()
    matched_by_name = False

    feed_urls = [
        feed["xml_url"],
        feed["html_url"],
    ]

    for key, package_names in package_map.items():
        for feed_url in feed_urls:
            if url_matches(
                feed_url,
                key,
            ):
                packages.update(
                    package_names
                )

    if not packages:
        name = feed["name"].casefold().strip()
        package = PACKAGES_BY_NAME.get(name)

        if package:
            packages.add(package)
            matched_by_name = True

    return sorted(
        packages,
        key=str.casefold,
    ), matched_by_name


def closest_package(feed_name):
    """
    Return up to two plausibly related template
    names for a feed that matched nothing,, or None.


    A candidate must contain the feed name or vice
    versa; the two closest ones are reported.


    """
    name = feed_name.casefold().strip()
    candidates = []

    for package in sorted(
        PACKAGES_BY_NAME.values(),
        key=str.casefold,
    ):
        pkg = package.casefold()

        if pkg == name:
            continue

        if pkg in name or name in pkg:
            candidates.append(package)


            if len(candidates) >= 2:
                break

    if not candidates:
        return None

    return ", ".join(candidates)


TEMPLATE_VERSION_RE = re.compile(
    r'^version="?([^"\n]+)"?\s*$',
    re.MULTILINE,
)


def load_repository_versions():
    """Current version of every package, read from its template.
    The README table is a generated artifact (`ocoman -u -m`)
    The template is the source of truth for what is actually built.
    """

    versions = {}

    if not SRC_PKGS.is_dir():
        return versions

    for template in sorted(SRC_PKGS.glob("*/template")):
        if template.parent.is_symlink():
            continue

        match = TEMPLATE_VERSION_RE.search(
            template.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )

        if not match:
            continue

        version_text = match.group(1).strip()

        version = extract_version(
            version_text
        )

        if version is None:
            continue

        package = template.parent.name

        versions[
            package.casefold()
        ] = {
            "name": package,
            "version": version,
            "version_text": version_text,
        }

    return versions


def fetch_feed(feed):
    try:
        request = urllib.request.Request(
            feed["xml_url"],
            headers={
                **DEFAULT_HEADERS,
                "Accept": (
                    "application/atom+xml, "
                    "application/rss+xml, "
                    "application/xml, "
                    "text/xml, */*"
                ),
                **auth_headers(feed["xml_url"]),
            },
        )

        with urllib.request.urlopen(
            request,
            timeout=30,
        ) as response:
            data = response.read()

        parsed = feedparser.parse(data)

        candidates = []

        for entry in parsed.entries:
            title = str(
                entry.get("title", "")
            ).strip()

            link = str(
                entry.get("link", "")
            ).strip()

            if not entry_allowed(
                title,
                feed["keep_rules"],
                feed["block_rules"],
            ):
                continue

            version = extract_version(
                title
            )

            if version is None:
                version = extract_version(
                    link
                )

            if version is None:
                continue

            candidates.append(
                {
                    "version": version,
                    "version_text": str(
                        version
                    ),
                    "title": title,
                    "link": link,
                }
            )

        if not candidates:
            return {
                **feed,
                "error":
                    "no valid version found",
            }

        latest = max(
            candidates,
            key=lambda item:
                item["version"],
        )

        return {
            **feed,
            **latest,
        }

    except Exception as exc:
        if isinstance(exc, urllib.error.HTTPError):
            detail = f"HTTP {exc.code} {exc.reason}"

            if exc.code in (401, 403, 429) and not auth_headers(feed["xml_url"]):
                detail += " (anonymous; set this forge's token)"

            return {
                **feed,
                "error": f"{feed['xml_url']}: {detail}",
            }

        return {
            **feed,
            "error": f"{feed['xml_url']}: {exc}",
        }


def load_issues():
    return json.loads(
        run_gh(
            [
                "issue",
                "list",
                "--repo",
                TARGET_REPO,
                "--state",
                "all",
                "--limit",
                "1000",
                "--json",
                (
                    "number,title,body,"
                    "state,url"
                ),
            ]
        )
    )


def marker(package):
    return (
        "<!-- package-update:"
        f"{package.casefold()} -->"
    )


def find_open_issue(
    issues,
    package,
):
    package_marker = marker(package)

    for issue in issues:
        if issue["state"] != "OPEN":
            continue

        body = issue.get("body") or ""

        if package_marker in body:
            return issue

    return None


def find_duplicate(
    issues,
    package,
    upstream_version,
):
    package_marker = marker(package)

    version_marker = (
        "<!-- upstream-version:"
        f"{upstream_version} -->"
    )

    for issue in issues:
        body = issue.get("body") or ""

        if (
            package_marker in body
            and version_marker in body
        ):
            return issue

    return None


def issue_version(issue):
    body = issue.get("body") or ""

    match = re.search(
        r"<!-- upstream-version:"
        r"([^\s]+) -->",
        body,
    )

    if match:
        return extract_version(
            match.group(1)
        )

    return extract_version(
        issue.get("title", "")
    )


AUTOBUMP_NO = "<!-- autobump:no -->"


def load_autobump_blacklist():
    """Templates excluded from automated autobumps
    (`src/autobump-blacklist`). Symlink aliases are handled by
    `autobump_eligible`, mirroring `autobump-blacklist.sh`.
    """
    if not AUTOBUMP_BLACKLIST.is_file():
        log(
            "WARN",
            "autobump-blacklist",
            f"{AUTOBUMP_BLACKLIST} is missing; "
            "every template will be marked as autobump-able",
        )
        return set()

    names = set()
    for line in AUTOBUMP_BLACKLIST.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            names.add(line.casefold())

    log(
        "INFO",
        "autobump-blacklist",
        f"{len(names)} package(s)",
    )

    return names


def autobump_eligible(package, blacklist):
    """Mirror of `.github/scripts/ci/autobump-blacklist.sh`: a template may
    be bumped automatically unless it is a symlink alias or listed in
    `src/autobump-blacklist`.
    """
    if (SRC_PKGS / package).is_symlink():
        return False

    return package.casefold() not in blacklist


def make_body(
    package,
    upstream_version,
    repository_version,
    result,
    autobump=False,
):
    notice = ""
    marker = ""

    if not autobump:
        notice = (
            "\nAutobump is not enabled for this template "
            "(listed in `src/autobump-blacklist` or a symlink "
            "alias); this issue is a head-up only.\n"
        )
        marker = f"{AUTOBUMP_NO}\n"

    return f"""## Package update

**Package:** `{package}`

**Repository version:** `{repository_version}`

**Upstream version:** `{upstream_version}`
{notice}
### Source

{result["link"]}

<!-- package-update:{package.casefold()} -->
<!-- upstream-version:{upstream_version} -->
<!-- source:{result["link"]} -->
{marker}"""


def ensure_label():
    result = subprocess.run(
        [
            "gh",
            "label",
            "create",
            ISSUE_LABEL,
            "--repo",
            TARGET_REPO,
            "--description",
            "Upstream package update",
            "--color",
            "1d76db",
            "--force",
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    if result.returncode != 0:
        print(
            "WARNING: unable to create label:",
            result.stderr.strip(),
            file=sys.stderr,
        )


def create_issue(
    package,
    repository_package,
    result,
    blacklist,
):
    upstream = result["version_text"]
    repository = (
        repository_package["version_text"]
    )

    title = (
        f"Update {package} "
        f"to {upstream}"
    )

    body = make_body(
        package,
        upstream,
        repository,
        result,
        autobump=autobump_eligible(
            package,
            blacklist,
        ),
    )

    if DRY_RUN:
        log(
            "CREATE",
            package,
            f"{repository} -> {upstream}"
            "  [dry-run]",
        )
        return

    url = run_gh(
        [
            "issue",
            "create",
            "--repo",
            TARGET_REPO,
            "--title",
            title,
            "--body",
            body,
        ]
    ).strip()

    try:
        run_gh(
            [
                "issue",
                "edit",
                url.rsplit("/", 1)[-1],
                "--repo",
                TARGET_REPO,
                "--add-label",
                ISSUE_LABEL,
            ]
        )
    except RuntimeError as error:
        log(
            "WARN",
            package,
            f"label {ISSUE_LABEL} not applied: {error}",
        )

    log(
        "CREATE",
        package,
        f"{repository} -> {upstream}  {url}",
    )


def update_issue(
    issue,
    package,
    repository_package,
    result,
    blacklist,
):
    upstream = result["version_text"]
    repository = (
        repository_package["version_text"]
    )

    title = (
        f"Update {package} "
        f"to {upstream}"
    )

    body = make_body(
        package,
        upstream,
        repository,
        result,
        autobump=autobump_eligible(
            package,
            blacklist,
        ),
    )

    if DRY_RUN:
        log(
            "UPDATE",
            package,
            f"#{issue['number']} {repository} -> {upstream}"
            "  [dry-run]",
        )
        return

    run_gh(
        [
            "issue",
            "edit",
            str(issue["number"]),
            "--repo",
            TARGET_REPO,
            "--title",
            title,
            "--body",
            body,
        ]
    )

    log(
        "UPDATE",
        package,
        f"#{issue['number']} {repository} -> {upstream}",
    )


def sync_issue_markers(issue, package, blacklist):
    """Repair stale `autobump:no` markers on an already-open issue.

    When `src/autobump-pkgs` disappeared (replaced by the blacklist),
    feedsparser marked every issue feed-only, so autobump.yml stopped
    opening PRs. Rewriting the body re-triggers autobump.yml on the
    `edited` event. Returns True when the body was (or, in dry-run,
    would be) rewritten.
    """
    body = issue.get("body") or ""
    has_no = AUTOBUMP_NO in body
    should_be_feed_only = not autobump_eligible(
        package,
        blacklist,
    )

    if has_no == should_be_feed_only:
        return False

    if DRY_RUN:
        log(
            "SYNC",
            package,
            f"#{issue['number']} "
            f"{'drop' if has_no else 'add'} {AUTOBUMP_NO}"
            "  [dry-run]",
        )
        return True

    if has_no:
        new_body = body.replace(
            f"\n{AUTOBUMP_NO}",
            "",
            1,
        )
    else:
        new_body = body + f"\n{AUTOBUMP_NO}"

    run_gh(
        [
            "issue",
            "edit",
            str(issue["number"]),
            "--repo",
            TARGET_REPO,
            "--body",
            new_body,
        ]
    )

    log(
        "SYNC",
        package,
        f"#{issue['number']} "
        f"{'removed' if has_no else 'added'} {AUTOBUMP_NO}",
    )

    return True


def close_issue(
    issue,
    package,
    repository_version,
):
    if DRY_RUN:
        log(
            "CLOSE",
            package,
            f"#{issue['number']}  repository={repository_version}"
            "  [dry-run]",
        )
        return

    run_gh(
        [
            "issue",
            "close",
            str(issue["number"]),
            "--repo",
            TARGET_REPO,
            "--comment",
            (
                f"`{package}` is now available "
                f"in OCO as version "
                f"`{repository_version}`."
            ),
        ]
    )

    log(
        "CLOSE",
        package,
        f"#{issue['number']}  repository={repository_version}",
    )


def process_feed(
    result,
    repository_versions,
    package_map,
    issues,
    stats,
    blacklist,
):
    feed_name = result["name"]

    if result.get("error"):
        stats["error"] += 1
        log(
            "ERROR",
            feed_name,
            result["error"],
        )
        return

    packages, matched_by_name = (
        find_packages_for_feed(
            result,
            package_map,
        )
    )

    if not packages:
        stats["miss"] += 1
        hint = closest_package(feed_name)

        detail = (
            "no OCO package matches feed"
            + (f"; closest: {hint}" if hint else "")
        )
        log("MISS", feed_name, detail)
        return

    upstream = result["version"]
    match_kind = "name" if matched_by_name else "URL"

    for package in packages:
        repository_package = (
            repository_versions.get(
                package.casefold()
            )
        )

        if repository_package is None:
            stats["miss"] += 1
            log(
                "MISS",
                package,
                "template exists but has no version= line",
            )
            continue

        repository_version = (
            repository_package["version"]
        )

        open_issue = find_open_issue(
            issues,
            package,
        )

        # Repair stale markers before deciding anything else, so a
        # once-marked feed-only issue can become autobump-able again.
        if open_issue and sync_issue_markers(
            open_issue,
            package,
            blacklist,
        ):
            stats["sync"] += 1
            issues = load_issues()

        # Already up-to-date.


        if upstream <= repository_version:
            stats["ok"] += 1
            detail = (
                f"up-to-date (repo {repository_version}.,  "
                f"{match_kind} match)"
            )

            if open_issue:
                close_issue(
                    open_issue,
                    package,
                    repository_package[
                        "version_text"
                    ],
                )
                detail = (
                    f"closed #{open_issue['number']}  "
                    f"(repo {repository_version}.,  "
                    f"{match_kind} match)"
                )

            log("OK", package, detail)
            continue

        # Upstream is newer.


        if open_issue:
            tracked_version = (
                issue_version(open_issue)
            )

            if (
                tracked_version is None
                or upstream > tracked_version
            ):
                stats["update"] += 1
                update_issue(
                    open_issue,
                    package,
                    repository_package,
                    result,
                    blacklist,
                )
            else:
                stats["skip"] += 1
                log(
                    "SKIP",
                    package,
                    f"issue #{open_issue['number']}  "
                    f"already tracks {tracked_version}",
                )

            continue

        # No open issue. Check closed issues too
        # to avoid creating the exact same issue again.
        duplicate = find_duplicate(
            issues,
            package,
            result["version_text"],
        )

        if duplicate:
            stats["skip"] += 1
            log(
                "SKIP",
                package,
                f"already tracked by #{duplicate['number']}",
            )
            continue

        stats["create"] += 1
        create_issue(
            package,
            repository_package,
            result,
            blacklist,
        )


def main():
    feeds = load_feeds()
    repository_versions = (
        load_repository_versions()
    )
    blacklist = load_autobump_blacklist()
    package_map = build_package_map()

    print(
        f"Feeds: {len(feeds)}"
    )

    print(
        f"OCO packages: "
        f"{len(repository_versions)}"
    )

    issues = load_issues()

    if DRY_RUN:
        log(
            "DRY_RUN",
            "label",
            f"would create label {ISSUE_LABEL!r}",
        )
    else:
        ensure_label()

    print("Fetching feeds...")

    results = []

    with ThreadPoolExecutor(
        max_workers=10
    ) as executor:
        futures = [
            executor.submit(
                fetch_feed,
                feed,
            )
            for feed in feeds
        ]

        for future in as_completed(
            futures
        ):
            results.append(
                future.result()
            )

    stats = {
        "ok": 0,
        "update": 0,
        "create": 0,
        "sync": 0,
        "skip": 0,
        "miss": 0,
        "error": 0,
    }

    for result in sorted(
        results,
        key=lambda item:
            item["name"].casefold(),
    ):
        before = (
            stats["create"],
            stats["update"],
            stats["sync"],
        )

        process_feed(
            result,
            repository_versions,
            package_map,
            issues,
            stats,
            blacklist,
        )


        after = (
            stats["create"],
            stats["update"],
            stats["sync"],
        )

        if after != before:
            issues = load_issues()

    print()

    log(
        "SUMMARY",
        "feeds",
        f"{len(results)}  "
        f"| ok {stats['ok']}  "
        f"| update {stats['update']}  "
        f"| create {stats['create']}  "
        f"| skip {stats['skip']}  "
        f"| sync {stats['sync']}  "
        f"| miss {stats['miss']}  "
        f"| error {stats['error']}",
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description=(
            "File and update package-update issues "
            "from src/feed.opml"
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=None,
        help=(
            "report what would change without "
            "touching GitHub"
        ),
    )

    args = parser.parse_args()

    if args.dry_run:
        os.environ["DRY_RUN"] = "1"
        globals()["DRY_RUN"] = True

    main()
