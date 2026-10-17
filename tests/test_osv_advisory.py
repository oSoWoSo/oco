#!/usr/bin/env python3
"""Focused tests for the non-blocking OSV autobump advisory check."""

import importlib.util
import json
from pathlib import Path
import tempfile
from urllib.error import URLError

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "osv_advisory", ROOT / ".github/scripts/osv-advisory.py"
)
osv = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(osv)


class Response:
    def __init__(self, value):
        self.payload = json.dumps(value).encode()

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return None

    def read(self):
        return self.payload


def mapping_file(value):
    temp = tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", delete=False)
    json.dump(value, temp)
    temp.close()
    return Path(temp.name)


def test_findings_and_query_identity():
    path = mapping_file({"packages": {"demo": {
        "type": "package", "ecosystem": "PyPI", "name": "demo-project"
    }}})
    captured = []

    def opener(request, timeout):
        captured.append((json.loads(request.data), timeout))
        return Response({"vulns": [{"id": "OSV-2", "aliases": ["CVE-2"], "summary": "bad *thing*"}]})

    report = osv.check(path, "demo", "2.0", opener)
    assert captured == [({"package": {"ecosystem": "PyPI", "name": "demo-project"}, "version": "2.0"}, 15)]
    assert r"OSV\-2" in report and r"CVE\-2" in report
    assert r"bad \*thing\*" in report
    path.unlink()


def test_all_upstream_omits_version_and_marks_scope():
    path = mapping_file({"packages": {"demo": {
        "type": "package", "ecosystem": "PyPI", "name": "demo-project"
    }}})
    captured = []

    def opener(request, timeout):
        captured.append(json.loads(request.data))
        return Response({"vulns": []})

    report = osv.check(path, "demo", "2.0", opener, all_upstream=True)
    assert captured == [{"package": {"ecosystem": "PyPI", "name": "demo-project"}}]
    assert "all upstream advisories" in report
    assert "displayed bumped version is contextual only" in report
    assert "No OSV advisories" in report
    path.unlink()


def test_affected_ranges_and_withdrawn_are_rendered():
    report = osv.make_report("demo", "2.0", "findings", [{
        "id": "OSV-1", "summary": "issue", "withdrawn": "2024-01-02T00:00:00Z",
        "affected": [{
            "versions": ["1.0", "1.1"],
            "ranges": [{"type": "SEMVER", "events": [
                {"introduced": "0"}, {"fixed": "1.2.0"}
            ]}],
        }],
    }], all_upstream=True)
    assert r"WITHDRAWN 2024\-01\-02T00:00:00Z" in report
    assert r"versions: 1\.0, 1\.1" in report
    assert r"SEMVER: introduced 0; fixed 1\.2\.0" in report
    assert "currently open" not in report


def test_fixed_and_open_advisories_are_highlighted():
    report = osv.make_report("demo", "2.0", "findings", [
        {
            "id": "CVE-2024-0001",
            "summary": "fixed issue",
            "affected": [{"ranges": [{"events": [{"introduced": "0"}, {"fixed": "1.2.0"}]}]}],
        },
        {
            "id": "CVE-2024-0002",
            "summary": "unfixed issue",
            "affected": [{"ranges": [{"events": [{"introduced": "0"}]}]}],
        },
    ], all_upstream=True)
    assert "- 🟢 **FIXED** — **CVE\\-2024\\-0001**" in report
    assert "- 🔴 **OPEN** — **CVE\\-2024\\-0002**" in report

def test_pagination_finds_later_page_and_sends_token():
    path = mapping_file({"packages": {"demo": {
        "type": "package", "ecosystem": "PyPI", "name": "demo"
    }}})
    captured = []
    pages = iter([
        {"vulns": [], "next_page_token": "page-2"},
        {"vulns": [{"id": "OSV-LATER", "summary": "later finding"}]},
    ])

    def opener(request, timeout):
        captured.append(json.loads(request.data))
        return Response(next(pages))

    report = osv.check(path, "demo", "1.0", opener)
    assert len(captured) == 2
    assert "page_token" not in captured[0]
    assert captured[1] == {
        "package": {"ecosystem": "PyPI", "name": "demo"},
        "version": "1.0",
        "page_token": "page-2",
    }
    assert r"OSV\-LATER" in report
    assert "later finding" in report
    path.unlink()


def test_pagination_rejects_malformed_and_repeated_tokens():
    path = mapping_file({"packages": {"demo": {
        "type": "package", "ecosystem": "PyPI", "name": "demo"
    }}})
    malformed = osv.check(
        path, "demo", "1.0",
        lambda *_a, **_k: Response({"vulns": [], "next_page_token": 42}),
    )
    assert "**ERROR:**" in malformed

    pages = iter([
        {"vulns": [], "next_page_token": "repeat"},
        {"vulns": [], "next_page_token": "repeat"},
    ])
    requests = []

    def repeated_token_opener(request, timeout):
        requests.append(request)
        return Response(next(pages))

    repeated = osv.check(path, "demo", "1.0", repeated_token_opener)
    assert len(requests) == 2
    assert "**ERROR:**" in repeated
    assert "No matching" not in repeated
    path.unlink()


def test_no_matches_and_unmapped_are_distinct():
    path = mapping_file({"packages": {"demo": {
        "type": "package", "ecosystem": "PyPI", "name": "demo"
    }}})
    report = osv.check(path, "demo", "1.0", lambda *_a, **_k: Response({"vulns": []}))
    assert "No matching OSV advisories" in report
    assert "not a clean bill" not in report
    unmapped = osv.check(path, "unknown", "1.0")
    assert "No OSV identity is configured" in unmapped
    assert "not** a clean bill of health" in unmapped
    path.unlink()


def test_git_identity_uses_only_reviewed_tag_template():
    path = mapping_file({"packages": {"demo": {
        "type": "git", "repo": "https://example.invalid/demo.git",
        "version_tag": "release-{version}-stable"
    }}})
    query = osv.load_identity(path, "demo", "3.4")
    assert query == {
        "package": {"ecosystem": "GIT", "name": "https://example.invalid/demo.git"},
        "version": "release-3.4-stable",
    }
    path.unlink()

    invalid = mapping_file({"packages": {"demo": {
        "type": "git", "repo": "https://example.invalid/demo.git", "version_tag": "v{version}-{guess}"
    }}})
    try:
        osv.load_identity(invalid, "demo", "3.4")
    except ValueError as exc:
        assert "no other braces" in str(exc)
    else:
        raise AssertionError("unreviewed tag template accepted")
    invalid.unlink()


def test_api_error_is_reported_not_clean():
    path = mapping_file({"packages": {"demo": {
        "type": "package", "ecosystem": "PyPI", "name": "demo"
    }}})

    def failed(*_args, **_kwargs):
        raise URLError("service unavailable")

    report = osv.check(path, "demo", "1.0", failed)
    assert "**ERROR:**" in report
    assert "service unavailable" in report
    assert "No matching" not in report
    path.unlink()


def test_report_escapes_untrusted_fields():
    report = osv.make_report("pkg<script>", "1.0", "findings", [{
        "id": "<OSV-1>", "summary": "x](/evil) & `code`"
    }])
    assert "&lt;script&gt;" in report
    assert r"&lt;OSV\-1&gt;" in report
    assert r"\]\(/evil\)" in report
    assert r"\`code\`" in report


def test_repository_mappings_have_template_evidence_and_valid_identity_schema():
    mapping_path = ROOT / ".github/osv-identities.json"
    data = json.loads(mapping_path.read_text(encoding="utf-8"))
    packages = data["packages"]
    counts = {kind: sum(entry.get("type") == kind for entry in packages.values())
              for kind in ("git", "package")}
    # Minimum inventory floors are not a claim that every package maps safely.
    # Resolve package dirs explicitly: globbing */template follows symlinked dirs.
    srcpkgs = ROOT / "srcpkgs"
    real_template_count = sum(
        1 for path in srcpkgs.iterdir()
        if path.is_dir() and not path.is_symlink()
        and (path / "template").is_file() and not (path / "template").is_symlink()
    )
    real_mappings = 0
    for package, entry in packages.items():
        package_dir = srcpkgs / package
        assert not package_dir.is_symlink(), (package, "mapping targets symlink alias")
        template = ROOT / entry["source_template"]
        assert not template.parent.is_symlink(), (package, "template parent is symlink")
        assert not template.is_symlink(), (package, "template is symlink")
        real_mappings += 1

    assert counts["git"] >= 100
    assert counts["package"] >= 4
    assert real_template_count >= 227
    assert real_mappings == len(packages) == 163
    assert real_mappings >= 150
    assert real_template_count >= real_mappings

    for package, entry in packages.items():
        template = ROOT / entry["source_template"]
        assert template.is_file(), (package, entry["source_template"])
        text = template.read_text(encoding="utf-8")
        distfiles = []
        lines = text.splitlines()
        for index, line in enumerate(lines):
            if not line.startswith("distfiles="):
                continue
            expression = line[len("distfiles="):]
            while expression.rstrip().endswith("\\") and index + 1 < len(lines):
                index += 1
                expression += lines[index].rstrip().removesuffix("\\")
            distfiles.append(expression)
        assert distfiles, (package, "template has no distfiles assignment")
        assert entry["source_url"] in " ".join(distfiles), (package, entry["source_url"])

        # The same loader used by the advisory helper is the mapping schema
        # validator; provenance keys must not alter the identity it produces.
        query = osv.load_identity(mapping_path, package, "1.2.3")
        assert query["package"]["ecosystem"] == ("GIT" if entry["type"] == "git"
                                                   else entry["ecosystem"])
        assert query["package"]["name"] == (entry["repo"] if entry["type"] == "git"
                                               else entry["name"])
        assert query["version"] == (entry["version_tag"].replace("{version}", "1.2.3")
                                    if entry["type"] == "git" else "1.2.3")


if __name__ == "__main__":
    for test in [test_findings_and_query_identity,
                 test_all_upstream_omits_version_and_marks_scope,
                 test_fixed_and_open_advisories_are_highlighted,
                 test_pagination_finds_later_page_and_sends_token,
                 test_pagination_rejects_malformed_and_repeated_tokens,
                 test_no_matches_and_unmapped_are_distinct,
                 test_git_identity_uses_only_reviewed_tag_template,
                 test_api_error_is_reported_not_clean, test_report_escapes_untrusted_fields,
                 test_repository_mappings_have_template_evidence_and_valid_identity_schema]:
        test()
    print("OSV advisory tests passed")
