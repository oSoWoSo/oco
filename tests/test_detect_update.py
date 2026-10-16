#!/usr/bin/env python3
"""Regression tests for xxautobump-compatible version selection."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DETECTOR = ROOT / ".github/scripts/detect-update.sh"


class DetectUpdateTests(unittest.TestCase):
    def detect(self, old_version, update_output):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            template = repo / "srcpkgs/fixture/template"
            template.parent.mkdir(parents=True)
            template.write_text(f"pkgname=fixture\nversion={old_version}\n")

            output_file = repo / "update-check.txt"
            output_file.write_text(update_output)
            engine = repo / "fake-xbps-src"
            engine.write_text(
                "#!/bin/sh\n"
                "[ \"$1\" = update-check ] && [ \"$2\" = fixture ] || exit 64\n"
                "cat \"$UPDATE_CHECK_OUTPUT\"\n"
            )
            engine.chmod(0o755)

            env = os.environ.copy()
            env["XBPS_SRC"] = str(engine)
            env["UPDATE_CHECK_OUTPUT"] = str(output_file)
            env.pop("GH_TOKEN", None)
            return subprocess.run(
                ["bash", str(DETECTOR), "fixture", str(repo)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

    def test_selects_version_sort_maximum(self):
        result = self.detect(
            "1.8.9",
            "found version fixture-1.10.0\n"
            "fixture-1.8.9 -> fixture-1.9.10\n"
            "fixture-1.8.9 -> fixture-1.10.0\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "fixture 1.8.9 1.10.0")

    def test_preserves_sort_v_prerelease_order(self):
        result = self.detect(
            "1.2.2",
            "found version fixture-1.2.3-rc.1\n"
            "fixture-1.2.2 -> fixture-1.2.3\n"
            "fixture-1.2.2 -> fixture-1.2.3-rc.1\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "fixture 1.2.2 1.2.3-rc.1")

    def test_no_candidates_produces_no_bump(self):
        result = self.detect("1.2.3", "")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
