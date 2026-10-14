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


if __name__ == "__main__":
    for test in [test_findings_and_query_identity, test_no_matches_and_unmapped_are_distinct,
                 test_git_identity_uses_only_reviewed_tag_template,
                 test_api_error_is_reported_not_clean, test_report_escapes_untrusted_fields]:
        test()
    print("OSV advisory tests passed")
