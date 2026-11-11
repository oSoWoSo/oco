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


if __name__ == "__main__":
    unittest.main(verbosity=2)