#!/usr/bin/env python3
"""Testing builds may reuse testing binaries without contaminating production."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / ".github/scripts/ci/build-repositories.sh"
CONFIGS = {
    "repos-remote.conf": "x86_64",
    "repos-remote-musl.conf": "x86_64-musl",
    "repos-remote-x86_64.conf": "x86_64",
    "repos-remote-x86_64-musl.conf": "x86_64-musl",
    "repos-remote-aarch64.conf": "aarch64",
    "repos-remote-aarch64-musl.conf": "aarch64-musl",
}


class BuildRepositoriesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.distdir = Path(self.temp.name)
        self.configs = self.distdir / "etc/xbps.d"
        self.configs.mkdir(parents=True)
        self.originals = {}
        for filename, arch in CONFIGS.items():
            self.originals[filename] = (
                f"repository=https://repo.osowoso.org/{arch}\n"
                "# Keep Void as a fallback\n"
                "repository=https://repo-ci.voidlinux.org/current\n"
            )
            (self.configs / filename).write_text(self.originals[filename])
        self.multilib = self.configs / "repos-remote-x86_64-multilib.conf"
        self.multilib.write_text("repository=https://repo-ci.voidlinux.org/current/multilib\n")
        self.multilib_before = self.multilib.read_bytes()

    def configure(self, channel=None):
        env = dict(os.environ, XBPS_DISTDIR=str(self.distdir))
        env.pop("BUILD_REPOSITORY_CHANNEL", None)
        if channel is not None:
            env["BUILD_REPOSITORY_CHANNEL"] = channel
        return subprocess.run(["bash", str(SCRIPT)], env=env, text=True, capture_output=True)

    def assert_configured(self, channel):
        for filename, arch in CONFIGS.items():
            prefix = f"repository=https://repo.osowoso.org/testing/{arch}\n" if channel == "testing" else ""
            self.assertEqual((self.configs / filename).read_text(), prefix + self.originals[filename])
        self.assertEqual(self.multilib.read_bytes(), self.multilib_before)

    def test_default_production_is_unchanged(self):
        result = self.configure()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_configured("production")

    def test_testing_precedes_production_for_host_and_cross_target_architectures(self):
        result = self.configure("testing")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_configured("testing")

    def test_testing_is_idempotent_and_preserves_permissions(self):
        modes = {p.name: p.stat().st_mode for p in self.configs.iterdir()}
        for _ in range(2):
            result = self.configure("testing")
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_configured("testing")
        self.assertEqual(modes, {p.name: p.stat().st_mode for p in self.configs.iterdir()})

    def test_production_removes_testing_configuration(self):
        self.assertEqual(self.configure("testing").returncode, 0)
        self.assertEqual(self.configure("production").returncode, 0)
        self.assert_configured("production")

    def test_arch_specific_files_are_optional(self):
        for name in CONFIGS:
            if name not in {"repos-remote.conf", "repos-remote-musl.conf"}:
                (self.configs / name).unlink()
        result = self.configure("testing")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.configs / "repos-remote.conf").read_text().startswith(
            "repository=https://repo.osowoso.org/testing/x86_64\n"))
        self.assertFalse((self.configs / "repos-remote-x86_64.conf").exists())

    def test_unsupported_channel_fails_before_modifying_files(self):
        result = self.configure("feature/unsafe")
        self.assertNotEqual(result.returncode, 0)
        self.assert_configured("production")

    def test_workflow_selects_by_source_branch_not_publication_destination(self):
        workflow = (ROOT / ".github/workflows/build.yml").read_text()
        selector = next(line for line in workflow.splitlines() if "BUILD_REPOSITORY_CHANNEL:" in line)
        self.assertIn("github.ref == 'refs/heads/testing'", selector)
        self.assertIn("github.event_name == 'pull_request'", selector)
        self.assertIn("github.event.pull_request.base.ref == 'testing'", selector)
        self.assertNotIn("publish_target", selector)
        for job in ("lint", "build"):
            # Restrict to this job, not a later job that happens to run it.
            remaining = workflow.split(f"\n  {job}:\n", 1)[1]
            block = re.split(r"\n  [a-z][a-z-]*:\n", remaining, maxsplit=1)[0]
            self.assertIn("build-repositories.sh", block)
            self.assertLess(block.index("build-repositories.sh"), block.index("build-merge-templates.sh"))


if __name__ == "__main__":
    unittest.main()
