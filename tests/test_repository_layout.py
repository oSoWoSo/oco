#!/usr/bin/env python3
"""The public website must never include source code or repository config."""
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WebsiteBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(ROOT / "website", self.root / "website")
        self.docs = self.root / "docs"

    def shell(self, script):
        return subprocess.run(["sh", "-c", '. "$1/lib/website.sh"; ' + script,
                               "test", str(ROOT), str(self.root)],
                              text=True, capture_output=True)

    def test_staging_is_an_allowlist_not_a_directory_upload(self):
        (self.root / "website/public/accidental.py").write_text("not public")
        (self.root / "website/public/private.conf").write_text("not public")
        result = self.shell('website_stage_assets "$2" "$2/docs"')
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = {"favicon.ico", "main.js", "manual.css", "manual.js", "style.css", "testing.html"}
        self.assertEqual({p.name for p in self.docs.iterdir()}, expected)
        self.assertFalse((self.docs / "main-index-template.html").exists())

    def test_symlink_assets_are_rejected(self):
        asset = self.root / "website/public/main.js"
        asset.unlink()
        asset.symlink_to(ROOT / "tools/autobump/autobump-release.py")
        result = self.shell('website_stage_assets "$2" "$2/docs"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe website asset", result.stderr)

    def test_upload_ignores_stale_code_config_and_templates_in_docs(self):
        self.docs.mkdir()
        for name in ("main.js", "index.html", "manual.html", "Manual.md", "testing.html",
                     "autobump-release.py", "feed.opml", "autobump-blacklist",
                     "main-index-template.html", "private.pem", "CNAME", "gallery.js",
                     "favicon.jpg", "CI.md", "SKILL.md", ".env", "requirements.txt"):
            (self.docs / name).write_text("fixture")
        source = (ROOT / "ocoman").read_text()
        function = re.search(r"^_upload_website_assets\(\) \{.*?^\}", source, re.M | re.S).group()
        result = self.shell('SCRIPT_DIR=$2; surf_auth_check() { return 0; }; '
                            'upload_file() { printf "UPLOAD:%s\\n" "${1##*/}"; }; '
                            'fatal() { exit 1; }; ' + function + '; _upload_website_assets')
        self.assertEqual(result.returncode, 0, result.stderr)
        uploaded = {line.removeprefix("UPLOAD:") for line in result.stdout.splitlines()
                    if line.startswith("UPLOAD:")}
        self.assertEqual(uploaded, {"main.js", "index.html", "manual.html", "Manual.md", "testing.html"})

    @unittest.skipUnless(shutil.which("pandoc"), "pandoc required for manual rendering")
    def test_manual_uses_relocated_template_without_network(self):
        source = self.root / "void"
        source.mkdir()
        (source / "Manual.md").write_text("# Local manual\n\nA local fixture.\n")
        output = self.docs / "manual.html"
        result = subprocess.run(["python3", str(ROOT / "tools/website/gen-manual.py"),
                                 str(self.root), str(output), "x86_64"],
                                env=dict(os.environ, XBPS_DISTDIR=str(source)),
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("A local fixture", output.read_text())
        self.assertEqual((self.docs / "Manual.md").read_bytes(), (source / "Manual.md").read_bytes())


class LayoutTests(unittest.TestCase):
    def test_legacy_source_and_ci_nesting_have_no_tracked_files(self):
        files = subprocess.check_output(["git", "ls-files"], cwd=ROOT, text=True).splitlines()
        self.assertFalse([p for p in files if p.startswith(("src/", ".github/scripts/ci/"))])

    def test_feed_defaults_follow_the_repository_not_the_tools_directory(self):
        spec = importlib.util.spec_from_file_location("layout_feeds", ROOT / "tools/updates/feedsparser.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(module.OCO_DIR, ROOT)
        self.assertEqual(module.OPML_PATH, ROOT / "config/feed.opml")
        self.assertEqual(module.AUTOBUMP_BLACKLIST, ROOT / "config/autobump-blacklist")


if __name__ == "__main__":
    unittest.main()
