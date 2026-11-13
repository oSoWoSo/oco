#!/usr/bin/env python3
"""Tests for the package-update issue filing logic (src/feedsparser.py).

These cover the pieces that regressed when the autobump whitelist
(`src/autobump-pkgs`) was replaced by `src/autobump-blacklist`:
eligibility now follows `autobump-blacklist.sh` (blacklist + symlink
aliases) and stale `<!-- autobump:no -->` markers get repaired.
"""

import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "feedsparser", ROOT / "src" / "feedsparser.py"
)
fs = None
_IMPORT_ERR = None
try:
    fs = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(fs)
except ImportError as exc:
    _IMPORT_ERR = exc


def _skip_if_missing():
    if fs is None:
        raise unittest.SkipTest(
            f"feedparser unavailable: {_IMPORT_ERR}"
        )


def make_tree(top: Path, blacklist=(), symlinks=()) -> Path:
    """Build a fake OCO tree: srcpkgs/NAME/template, autobump-blacklist."""
    top = top / "oco"
    (top / "srcpkgs").mkdir(parents=True)
    for name in ("llama.cpp", "brave-browser-bin", "favnyr", "glaze"):
        pkg = top / "srcpkgs" / name
        pkg.mkdir()
        (pkg / "template").write_text(
            f"version=\"{name}\"\"\n", encoding="utf-8"
        )
    for name in symlinks:
        (top / "srcpkgs" / name).symlink_to(
            top / "srcpkgs" / "glaze"
        )
    (top / "src").mkdir()
    (top / "src" / "autobump-blacklist").write_text(
        "\n".join(blacklist) + "\n",
        encoding="utf-8",
    )
    return top


def make_issue(body):
    return {"state": "OPEN", "number": 1, "body": body, "url": "https://x/1"}


def _rmtree(path):
    import shutil
    shutil.rmtree(path, ignore_errors=True)


class BlacklistTests(unittest.TestCase):
    def setUp(self):
        _skip_if_missing()
        self._tmp = Path(tempfile.mkdtemp())
        self.addCleanup(_rmtree, self._tmp)
        self.top = make_tree(
            self._tmp,
            blacklist=("glaze", "notesnook"),
            symlinks=(),
        )
        fs.SRC_PKGS = self.top / "srcpkgs"
        fs.AUTOBUMP_BLACKLIST = self.top / "src" / "autobump-blacklist"

    def test_blacklist_loaded(self):
        self.assertIn(
            "glaze", fs.load_autobump_blacklist()
        )

    def test_eligible_not_blacklisted(self):
        self.assertTrue(
            fs.autobump_eligible("llama.cpp", fs.load_autobump_blacklist())
        )

    def test_ineligible_when_blacklisted(self):
        self.assertFalse(
            fs.autobump_eligible("glaze", fs.load_autobump_blacklist())
        )

    def test_ineligible_when_symlink_alias(self):
        import os
        (self.top / "srcpkgs" / "CRC-hyprland").symlink_to(
            self.top / "srcpkgs" / "glaze",
            target_is_directory=True,
        )
        self.assertTrue(fs.autobump_eligible("llama.cpp", set()))
        self.assertFalse(fs.autobump_eligible("CRC-hyprland", set()))


class MarkersTests(unittest.TestCase):
    def setUp(self):
        _skip_if_missing()
        self._tmp = Path(tempfile.mkdtemp())
        self.addCleanup(_rmtree, self._tmp)
        self.top = make_tree(self._tmp, blacklist=("glaze",))
        fs.SRC_PKGS = self.top / "srcpkgs"
        fs.AUTOBUMP_BLACKLIST = self.top / "src" / "autobump-blacklist"
        fs.DRY_RUN = False

    def test_make_body_head_up_only(self):
        body = fs.make_body(
            "llama.cpp",
            "0.9.0",
            "0.8.0",
            {"link": "https://github.com/ggml-org/llama.cpp/releases/tag/v0.9.0"},
            autobump=False,
        )
        self.assertIn(fs.AUTOBUMP_NO, body)
        self.assertIn("autobump-blacklist", body)

    def test_make_body_autobump_able(self):
        body = fs.make_body(
            "llama.cpp",
            "0.9.0",
            "0.8.0",
            {"link": "https://github.com/ggml-org/llama.cpp/releases/tag/v0.9.0"},
            autobump=True,
        )
        self.assertNotIn(fs.AUTOBUMP_NO, body)

    def test_sync_removes_stale_no(self):
        """A stale feed-only marker on an autobump-able template is dropped."""
        issue = make_issue(
            "**Upstream version:** `0.9.0`\n" + fs.AUTOBUMP_NO + "\n"
        )
        calls = []

        def fake_gh(args):
            calls.append(args)
            return '1\n'

        fs.run_gh = fake_gh
        self.assertTrue(fs.sync_issue_markers(issue, "llama.cpp", set()))
        self.assertNotIn(fs.AUTOBUMP_NO, calls[0][calls[0].index("--body") + 1])
        self.assertIn("issue", calls[0][0])

    def test_sync_adds_missing_no(self):
        """A blacklisted template whose open issue lacks the marker gets it."""
        issue = make_issue("**Upstream version:** `0.3.8`\n")
        calls = []

        def fake_gh(args):
            calls.append(args)
            return '1\n'

        fs.run_gh = fake_gh
        self.assertTrue(fs.sync_issue_markers(issue, "glaze", {"glaze"}))
        new_body = calls[0][calls[0].index("--body") + 1]
        self.assertIn(fs.AUTOBUMP_NO, new_body)

    def test_sync_noop_when_marker_matches(self):
        issue = make_issue(
            "**Upstream version:** `0.9.0`\n" + fs.AUTOBUMP_NO + "\n"
        )

        def fail_gh(_args):
            raise AssertionError("must not touch GitHub")

        fs.run_gh = fail_gh
        self.assertFalse(
            fs.sync_issue_markers(
                issue, "glaze", {"glaze"}
            )
        )


def make_pkg_issue(number, version, state="OPEN"):
    """Issue for the `llama.cpp` template carrying the standard markers."""
    return {
        "state": state,
        "number": number,
        "body": (
            "**Package:** `llama.cpp`\n"
            f"**Upstream version:** `{version}`\n"
            f"<!-- package-update:llama.cpp -->\n"
            f"<!-- upstream-version:{version} -->"
        ),
        "url": f"https://x/{number}",
    }


class SupersedeIssuesTests(unittest.TestCase):
    def setUp(self):
        _skip_if_missing()
        self._tmp = Path(tempfile.mkdtemp())
        self.addCleanup(_rmtree, self._tmp)
        self.top = make_tree(self._tmp)
        fs.SRC_PKGS = self.top / "srcpkgs"
        fs.AUTOBUMP_BLACKLIST = self.top / "src" / "autobump-blacklist"
        fs.DRY_RUN = False

    def test_keeps_one_and_closes_older_as_not_planned(self):
        """Only the newest open issue survives; older ones are obsolete."""
        keep = make_pkg_issue(2, "0.9.0")
        older = make_pkg_issue(1, "0.8.0")
        calls = []

        def fake_gh(args):
            calls.append(args)
            return ""

        fs.run_gh = fake_gh
        obsolete = fs.supersede_issues(
            [keep, older],
            "llama.cpp",
            keep,
        )

        self.assertEqual([issue["number"] for issue in obsolete], [1])
        self.assertEqual(len(calls), 1)
        close_args = calls[0]
        self.assertEqual(close_args[0], "issue")
        self.assertEqual(close_args[1], "close")
        self.assertIn("1", close_args)
        self.assertIn("--reason", close_args)
        self.assertEqual(
            close_args[close_args.index("--reason") + 1],
            "not planned",
        )

    def test_newest_issue_for_template_is_kept_even_when_not_newest_among_open(self):
        """The caller's keep_issue is preserved regardless of version."""
        keep = make_pkg_issue(1, "0.8.0")
        newer = make_pkg_issue(2, "0.9.0")
        calls = []

        def fake_gh(args):
            calls.append(args)
            return ""

        fs.run_gh = fake_gh
        obsolete = fs.supersede_issues(
            [keep, newer],
            "llama.cpp",
            keep,
        )

        self.assertEqual([issue["number"] for issue in obsolete], [2])
        self.assertEqual(len(calls), 1)

    def test_other_templates_and_closed_issues_are_left_alone(self):
        keep = make_pkg_issue(3, "0.9.0")
        older = make_pkg_issue(2, "0.8.0")
        closed = make_pkg_issue(1, "0.7.0", state="CLOSED")
        other_pkg = {
            "state": "OPEN",
            "number": 4,
            "body": (
                "**Package:** `glaze`\n"
                "**Upstream version:** `0.4.0`\n"
                "<!-- package-update:glaze -->\n"
                "<!-- upstream-version:0.4.0 -->"
            ),
            "url": "https://x/4",
        }
        calls = []

        def fake_gh(args):
            calls.append(args)
            return ""

        fs.run_gh = fake_gh
        obsolete = fs.supersede_issues(
            [keep, older, closed, other_pkg],
            "llama.cpp",
            keep,
        )

        self.assertEqual([issue["number"] for issue in obsolete], [2])
        self.assertEqual(len(calls), 1)
        self.assertIn("2", calls[0])

    def test_dry_run_closes_nothing(self):
        keep = make_pkg_issue(2, "0.9.0")
        older = make_pkg_issue(1, "0.8.0")
        fs.DRY_RUN = True

        def fail_gh(_args):
            raise AssertionError("must not touch GitHub")

        fs.run_gh = fail_gh
        obsolete = fs.supersede_issues(
            [keep, older],
            "llama.cpp",
            keep,
        )

        self.assertEqual([issue["number"] for issue in obsolete], [1])


if __name__ == "__main__":
    unittest.main(verbosity=2)