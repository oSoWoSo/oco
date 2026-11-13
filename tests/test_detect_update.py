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
    def detect(self, old_version, update_output, *, euid=1000, token=None):
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

            fake_bin = repo / "bin"
            fake_bin.mkdir()
            fake_id = fake_bin / "id"
            fake_id.write_text(f"#!/bin/sh\necho {euid}\n")
            fake_id.chmod(0o755)
            sudo_args = repo / "sudo-args"
            fake_sudo = fake_bin / "sudo"
            fake_sudo.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"$@\" >\"$SUDO_ARGS\"\n"
                "[ \"$1\" = -Eu ] && [ \"$2\" = builder ] || exit 65\n"
                "shift 2\n"
                "exec \"$@\"\n"
            )
            chown_args = repo / "chown-args"
            fake_chown = fake_bin / "chown"
            fake_chown.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"$@\" >\"$CHOWN_ARGS\"\n"
            )
            fake_chown.chmod(0o755)
            fake_sudo.chmod(0o755)

            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}:{env['PATH']}"
            env["XBPS_SRC"] = str(engine)
            env["UPDATE_CHECK_OUTPUT"] = str(output_file)
            env["SUDO_ARGS"] = str(sudo_args)
            env["CHOWN_ARGS"] = str(chown_args)
            env.pop("GH_TOKEN", None)
            if token is not None:
                env["GH_TOKEN"] = token
            result = subprocess.run(
                ["bash", str(DETECTOR), "fixture", str(repo)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            self.last_sudo_args = sudo_args.read_text().splitlines() if sudo_args.exists() else []
            self.last_chown_args = chown_args.read_text().splitlines() if chown_args.exists() else []
            self.last_engine = str(engine)
            return result

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


    def test_root_runs_update_check_as_builder_and_transfers_token_file_access(self):
        result = self.detect("1.2.3", "", euid=0, token="test-token")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.last_sudo_args,
            ["-Eu", "builder", self.last_engine, "update-check", "fixture"],
        )
        self.assertEqual(self.last_chown_args[:2], ["-R", "builder:builder"])

if __name__ == "__main__":
    unittest.main()
