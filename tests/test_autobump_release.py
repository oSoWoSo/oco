#!/usr/bin/env python3
"""Regression tests for the autobump release validation of batch pull requests."""

import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "autobump_release", ROOT / "src/autobump-release.py"
)
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ArchTests(unittest.TestCase):
    """A skipped architecture is only allowed when the template says so."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.templates = self.tmp / "srcpkgs"
        self.templates.mkdir(parents=True)

    def write(self, name: str, body: str) -> None:
        directory = self.templates / name
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "template").write_text(body, encoding="utf-8")

    def patterns(self, name: str) -> list[str]:
        return release.package_arch_patterns(self.templates, name)

    def test_no_restriction_means_every_architecture(self):
        self.write("demo", "pkgname=demo\nversion=1.0\nrevision=1\n")
        self.assertEqual(self.patterns("demo"), [])
        self.assertTrue(release.arch_matches([], "x86_64"))

    def test_explicit_architecture(self):
        self.write("demo", 'pkgname=demo\nversion=1.0\nrevision=1\narchs="x86_64"\n')
        self.assertTrue(release.arch_matches(self.patterns("demo"), "x86_64"))
        self.assertFalse(release.arch_matches(self.patterns("demo"), "aarch64"))

    def test_exclusion_only_list(self):
        self.write("demo", "pkgname=demo\nversion=1.0\nrevision=1\narchs=\"~i686\"\n")
        self.assertTrue(release.arch_matches(self.patterns("demo"), "x86_64"))
        self.assertFalse(release.arch_matches(self.patterns("demo"), "i686"))

    def test_glob_pattern(self):
        self.write("demo", 'pkgname=demo\nversion=1.0\nrevision=1\narchs="x86_64*"\n')
        self.assertTrue(release.arch_matches(self.patterns("demo"), "x86_64"))
        self.assertTrue(release.arch_matches(self.patterns("demo"), "x86_64-musl"))
        self.assertFalse(release.arch_matches(self.patterns("demo"), "aarch64"))

    def test_missing_template_has_no_restriction(self):
        self.assertEqual(self.patterns("ghost"), [])


class StageTests(unittest.TestCase):
    """Every changed package needs its own successful source result."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.artifacts = self.tmp / "artifacts"
        self.staging = self.tmp / "staging"
        self.templates = self.tmp / "srcpkgs"
        self.templates.mkdir(parents=True)
        (self.templates / "alpha").mkdir()
        (self.templates / "alpha" / "template").write_text(
            "pkgname=alpha\nversion=1.1\nrevision=1\n", encoding="utf-8")
        (self.templates / "beta").mkdir()
        (self.templates / "beta" / "template").write_text(
            "pkgname=beta\nversion=2.0\nrevision=3\n", encoding="utf-8")

        self.plan = {
            "matrix": {"config": [
                {"arch": "x86_64", "host": "x86_64"},
                {"arch": "aarch64", "host": "aarch64"},
            ]},
        }
        self.versions = {"alpha": "1.1", "beta": "2.0"}

    def make_artifact(self, arch: str, host: str, rows: list[str],
                      files: list[str] | None = None) -> None:
        folder = self.artifacts / f"autobump-bin-{arch}-{host}"
        packages = folder / "packages"
        packages.mkdir(parents=True)
        entries = []
        for name in files if files is not None else [f"{arch}-demo-1.0_1.{arch}.xbps"]:
            payload = b"binary"
            (packages / name).write_bytes(payload)
            entries.append({"name": name, "sha256": hashlib.sha256(payload).hexdigest()})
        results = folder / "results.tsv"
        results.write_text("\n".join(rows) + "\n", encoding="utf-8")
        manifest = {"arch": arch, "host": host, "files": entries,
                    "results_sha256": sha256(results)}
        (folder / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")

    def plan_artifact(self) -> None:
        folder = self.artifacts / "autobump-release-plan"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "release.json").write_text("{}", encoding="utf-8")

    def stage(self) -> int:
        return release.stage(self.artifacts, self.staging, self.plan,
                             self.versions, self.templates)

    def test_batch_with_every_package_built_is_accepted(self):
        self.plan_artifact()
        rows = ["alpha\t1.1\tok", "beta\t2.0\tok"]
        self.make_artifact("x86_64", "x86_64", rows)
        self.make_artifact("aarch64", "aarch64", rows)
        self.assertEqual(self.stage(), 2)

    def test_a_package_without_a_result_is_rejected(self):
        self.plan_artifact()
        rows = ["alpha\t1.1\tok"]
        self.make_artifact("x86_64", "x86_64", rows)
        self.make_artifact("aarch64", "aarch64", rows)
        with self.assertRaises(ValueError) as error:
            self.stage()
        self.assertIn("beta", str(error.exception))

    def test_a_failing_package_is_rejected(self):
        self.plan_artifact()
        rows = ["alpha\t1.1\tok", "beta\t2.0\tfail"]
        self.make_artifact("x86_64", "x86_64", rows)
        self.make_artifact("aarch64", "aarch64", rows)
        with self.assertRaises(ValueError):
            self.stage()

    def test_a_wrong_version_is_rejected(self):
        self.plan_artifact()
        rows = ["alpha\t1.1\tok", "beta\t1.9\tok"]
        self.make_artifact("x86_64", "x86_64", rows)
        self.make_artifact("aarch64", "aarch64", rows)
        with self.assertRaises(ValueError):
            self.stage()

    def test_a_duplicate_result_is_rejected(self):
        self.plan_artifact()
        rows = ["alpha\t1.1\tok", "alpha\t1.1\tok", "beta\t2.0\tok"]
        self.make_artifact("x86_64", "x86_64", rows)
        self.make_artifact("aarch64", "aarch64", rows)
        with self.assertRaises(ValueError):
            self.stage()

    def test_a_skip_is_only_allowed_for_an_excluded_architecture(self):
        (self.templates / "alpha" / "template").write_text(
            "pkgname=alpha\nversion=1.1\nrevision=1\narchs=\"x86_64\"\n", encoding="utf-8")
        self.plan_artifact()
        self.make_artifact("x86_64", "x86_64",
                           ["alpha\t1.1\tok", "beta\t2.0\tok"])
        self.make_artifact("aarch64", "aarch64",
                           ["alpha\t1.1\tskip", "beta\t2.0\tok"])
        self.assertEqual(self.stage(), 2)

    def test_a_skip_on_a_supported_architecture_is_rejected(self):
        self.plan_artifact()
        self.make_artifact("x86_64", "x86_64",
                           ["alpha\t1.1\tskip", "beta\t2.0\tok"])
        self.make_artifact("aarch64", "aarch64",
                           ["alpha\t1.1\tskip", "beta\t2.0\tok"])
        with self.assertRaises(ValueError):
            self.stage()


class CheckPrTests(unittest.TestCase):
    """A batch pull request carries every changed template."""

    def setUp(self):
        self.plan = {
            "pr_number": 7,
            "head_ref": "autobump/alpha-1.1",
            "head_sha": "a" * 40,
            "base_sha": "b" * 40,
            "packages": "alpha beta",
            "removed": "",
        }
        self.pr = {
            "number": 7,
            "base": {"ref": "OCO", "sha": "b" * 40},
            "head": {"repo": {"full_name": "oSoWoSo/oco"}, "sha": "a" * 40,
                     "ref": "autobump/alpha-1.1"},
            "user": {"login": "oSoWoSo-bot"},
            "changed_files": 3,
            "state": "open",
            "merged": False,
        }

    def files(self, paths: list[str]) -> list[dict]:
        return [{"filename": path, "status": "modified"} for path in paths]

    def test_a_batch_of_templates_is_accepted(self):
        packages = release.check_pr(
            self.pr,
            self.files(["README.md", "srcpkgs/alpha/template", "srcpkgs/beta/template"]),
            repo="oSoWoSo/oco", plan=self.plan, allow_merged=True)
        self.assertEqual(packages, ["alpha", "beta"])

    def test_a_pr_that_touches_an_unexpected_file_is_rejected(self):
        with self.assertRaises(ValueError):
            release.check_pr(
                self.pr,
                self.files(["README.md", "srcpkgs/alpha/template", "srcpkgs/beta/template",
                            "src/other.txt"]),
                repo="oSoWoSo/oco", plan=self.plan, allow_merged=True)

    def test_a_pr_that_adds_a_template_is_rejected(self):
        files = self.files(["srcpkgs/alpha/template", "srcpkgs/beta/template"])
        files[0] = {"filename": "srcpkgs/alpha/template", "status": "added"}
        with self.assertRaises(ValueError):
            release.check_pr(self.pr, files, repo="oSoWoSo/oco", plan=self.plan,
                             allow_merged=True)

    def test_a_plan_that_does_not_match_the_templates_is_rejected(self):
        with self.assertRaises(ValueError):
            release.check_pr(
                self.pr,
                self.files(["srcpkgs/alpha/template"]),
                repo="oSoWoSo/oco", plan=self.plan, allow_merged=True)


if __name__ == "__main__":
    unittest.main()
