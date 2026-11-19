#!/usr/bin/env python3
"""Regression tests for the VUR check dependency closure (vur-closure.py).

The VUR check pushes all templates changed by a PR -- plus every OCO-only
template they need at build time -- onto ONE branch of the void-packages fork
so the official build.yaml runs once.  These tests pin down what the closure
carries: OCO-only pack members and OCO-only transitive build dependencies,
but never templates already present on VUR master.
"""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / ".github/scripts/vur-closure.py"


def run_helper(root: Path, changed: str, upstream: Path | None = None) -> subprocess.CompletedProcess:
    cmd = [sys.executable, str(HELPER), "--root", str(root), "--changed", changed]
    if upstream is not None:
        cmd += ["--upstream", str(upstream)]
    return subprocess.run(cmd, capture_output=True, text=True)


def write_template(root: Path, name: str, deps: list[str] | None = None) -> None:
    directory = root / "srcpkgs" / name
    directory.mkdir(parents=True, exist_ok=True)
    body = f"pkgname={name}\nversion=1\nrevision=1\n"
    if deps:
        body += "depends=\"" + " ".join(deps) + "\"\n"
    (directory / "template").write_text(body, encoding="utf-8")


class ClosureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        (self.tmp / "config").mkdir(parents=True)
        (self.tmp / "srcpkgs").mkdir()
        self.upstream = self.tmp / "upstream.txt"
        self.upstream.write_text("", encoding="utf-8")

    def set_packs(self, *pairs: tuple[str, str]) -> None:
        (self.tmp / "config" / "autobump-packs.tsv").write_text(
            "".join(f"{pack}\t{member}\n" for pack, member in pairs), encoding="utf-8")

    def set_manifest(self, *rows: tuple[str, list[str]]) -> None:
        body = ["# autobump-dependencies-v1"]
        for pkg, deps in rows:
            body.append(f"{pkg}\t{len(deps):x}\t{' '.join(deps)}")
        (self.tmp / "config" / "autobump-dependencies.tsv").write_text(
            "\n".join(body) + "\n", encoding="utf-8")

    def test_changed_template_is_carried_even_when_upstream(self):
        write_template(self.tmp, "alpha")
        self.upstream.write_text("alpha\n", encoding="utf-8")
        result = run_helper(self.tmp, "alpha", self.upstream)
        # A changed template must be tested even if VUR master already ships it.
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), ["alpha"])

    def test_upstream_dependency_is_not_carried(self):
        write_template(self.tmp, "app", deps=["already-void"])
        write_template(self.tmp, "already-void")
        # app depends on a package void-packages already ships: do not copy it.
        self.upstream.write_text("already-void\n", encoding="utf-8")
        self.set_manifest(("app", ["already-void"]))
        result = run_helper(self.tmp, "app", self.upstream)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), ["app"])

    def test_full_pack_carried_for_changed_member(self):
        for member in ("pac-a", "pac-b", "pac-c"):
            write_template(self.tmp, member)
        self.set_packs(("sonic", "pac-a"), ("sonic", "pac-b"), ("sonic", "pac-c"))
        result = run_helper(self.tmp, "pac-b", self.upstream)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), ["pac-a", "pac-b", "pac-c"])

    def test_pack_only_applies_to_oco_only_members(self):
        write_template(self.tmp, "pac-a")
        write_template(self.tmp, "pac-b")
        # pac-a exists in void-packages too; only pac-b must be carried.
        self.upstream.write_text("pac-a\n", encoding="utf-8")
        self.set_packs(("sonic", "pac-a"), ("sonic", "pac-b"))
        result = run_helper(self.tmp, "pac-b", self.upstream)
        self.assertEqual(result.stdout.split(), ["pac-b"])

    def test_transitive_oco_only_dependencies_are_carried(self):
        write_template(self.tmp, "app", deps=["sf-cmake-modules"])
        write_template(self.tmp, "sf-cmake-modules", deps=["sonic-namespace"])
        write_template(self.tmp, "sonic-namespace")
        # sonic-namespace exists upstream; sf-cmake-modules is OCO-only.
        self.upstream.write_text("app\nsonic-namespace\n", encoding="utf-8")
        self.set_manifest(("sf-cmake-modules", ["sonic-namespace"]))
        result = run_helper(self.tmp, "app", self.upstream)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.split(),
            ["app", "sf-cmake-modules"],  # sonic-namespace already upstream
        )

    def test_manifest_missing_falls_back_to_template_parse(self):
        write_template(self.tmp, "app", deps=["oco-dep"])
        write_template(self.tmp, "oco-dep")
        # No manifest row for either package; literal template parse used.
        result = run_helper(self.tmp, "app", self.upstream)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), ["app", "oco-dep"])

    def test_alias_changed_name_resolves_to_real_dir(self):
        write_template(self.tmp, "Community-Repositories-Collection")
        os.symlink(
            "Community-Repositories-Collection",
            self.tmp / "srcpkgs" / "CRC-black-hole",
        )
        result = run_helper(self.tmp, "CRC-black-hole", self.upstream)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), ["Community-Repositories-Collection"])

    def test_missing_changed_template_is_ignored_with_warning(self):
        write_template(self.tmp, "alpha")
        result = run_helper(self.tmp, "nonexistent alpha", self.upstream)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nonexistent", result.stderr)
        self.assertEqual(result.stdout.split(), ["alpha"])


if __name__ == "__main__":
    unittest.main(verbosity=2)