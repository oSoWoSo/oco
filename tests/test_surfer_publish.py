#!/usr/bin/env python3
"""Contract tests for the Surfer publication artifact validator."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("surfer_publish", ROOT / "src/surfer-publish.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class PublicationRequestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.manifest = {
            "schema_version": 1,
            "destination": "production",
            "source_sha": "a" * 40,
            "source_run_id": "12345",
            "package_arches": ["x86_64"],
            "result_arches": ["x86_64"],
            "purge_packages": ["gone"],
            "update_arch_pages": True,
            "update_feed": True,
            "update_main_index": False,
        }
        (self.root / "packages/x86_64").mkdir(parents=True)
        (self.root / "packages/x86_64/pkg-1.0_1.x86_64.xbps").write_bytes(b"binary")
        (self.root / "results").mkdir()
        (self.root / "results/x86_64.tsv").write_text("pkg\t1.0_1\tok\n")
        (self.root / "purge-packages.txt").write_text("gone\n")
        self.write_manifest()

    def tearDown(self):
        self.temp.cleanup()

    def write_manifest(self):
        (self.root / "manifest.json").write_text(json.dumps(self.manifest))

    def invalid(self, destination="production"):
        with self.assertRaises(validator.RequestError):
            validator.validate(self.root, destination)


    def test_all_supplied_packages_are_accepted(self):
        for name in (
            "hyprland-protocols-0.8.0_2.x86_64.xbps",
            "package-1.0~rc1_2.x86_64.xbps",
        ):
            (self.root / "packages/x86_64" / name).write_bytes(b"binary")

        self.assertEqual(validator.validate(self.root, "production"), self.manifest)

    def test_valid_production_and_testing(self):
        self.assertEqual(validator.validate(self.root, "production"), self.manifest)
        self.manifest["destination"] = "testing"
        self.write_manifest()
        self.assertEqual(validator.validate(self.root, "testing"), self.manifest)

    def test_destination_mismatch(self):
        self.invalid("testing")

    def test_malformed_sha_and_run_id(self):
        for key, value in (("source_sha", "bad"), ("source_run_id", "12x")):
            with self.subTest(key=key):
                self.manifest[key] = value
                self.write_manifest()
                self.invalid()
                self.manifest[key] = "a" * 40 if key == "source_sha" else "12345"

    def test_unknown_manifest_fields_are_rejected(self):
        self.manifest["extra"] = True
        self.write_manifest()
        self.invalid()

    def test_unsafe_purge_names_and_duplicate_or_unsupported_arches(self):
        self.manifest["purge_packages"] = ["../escape"]
        self.write_manifest()
        self.invalid()
        self.manifest["purge_packages"] = ["gone"]
        self.manifest["package_arches"] = ["x86_64", "x86_64"]
        self.write_manifest()
        self.invalid()
        self.manifest["package_arches"] = ["unknown"]
        self.write_manifest()
        self.invalid()

    def test_missing_declared_package_and_results_payloads(self):
        (self.root / "packages/x86_64/pkg-1.0_1.x86_64.xbps").unlink()
        self.invalid()
        (self.root / "packages/x86_64/pkg-1.0_1.x86_64.xbps").write_bytes(b"binary")
        (self.root / "results/x86_64.tsv").unlink()
        self.invalid()

    def test_undeclared_extra_and_traversal_payloads_are_rejected(self):
        (self.root / "stray").write_text("extra")
        self.invalid()
        (self.root / "stray").unlink()
        (self.root / "packages/x86_64/../escape.xbps").write_text("bad")
        self.invalid()

    def test_feed_without_results_is_rejected(self):
        self.manifest["result_arches"] = []
        self.write_manifest()
        self.invalid()

    def test_symlink_payload_is_rejected(self):
        (self.root / "link").symlink_to(self.root / "manifest.json")
        self.invalid()


class PublicationCreationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "surfer-publication"

    def create(self, **kwargs):
        return validator.create(self.root, "production", "a" * 40, "123", **kwargs)

    def script(self, name, **env):
        result = subprocess.run(["bash", str(ROOT / ".github/scripts/ci" / name)],
                                cwd=ROOT, env=dict(os.environ, RUNNER_TEMP=self.temp.name, **env),
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads((self.root / "manifest.json").read_text())

    def test_metadata_only_and_automatic_cleanup(self):
        manifest = self.create(update_main_index=True)
        self.assertTrue(manifest["update_main_index"])
        self.assertEqual(manifest["package_arches"], [])
        manifest = self.create()
        self.assertFalse(manifest["update_main_index"])

    def test_payloads_are_discovered_and_validated(self):
        packages = self.root / "packages/x86_64"
        packages.mkdir(parents=True)
        (packages / "fixture-1_1.x86_64.xbps").write_bytes(b"binary")
        results = self.root / "results"
        results.mkdir()
        (results / "x86_64.tsv").write_text("fixture\t1\tok\n")
        manifest = self.create(update_feed=True, update_arch_pages=True)
        self.assertEqual(manifest["package_arches"], ["x86_64"])
        self.assertEqual(manifest["result_arches"], ["x86_64"])
        self.assertEqual(validator.validate(self.root, "production"), manifest)

    def test_invalid_requests_fail_at_creation(self):
        for kwargs in ({"purge_packages": ["../escape"]}, {"update_feed": True}):
            with self.subTest(kwargs=kwargs), self.assertRaises(validator.RequestError):
                self.create(**kwargs)

    def test_purge_list_is_updated_and_cleared(self):
        self.create(purge_packages=["one", "two"])
        self.assertEqual((self.root / "purge-packages.txt").read_text(), "one\ntwo\n")
        self.create()
        self.assertFalse((self.root / "purge-packages.txt").exists())

    def test_cleanup_accepts_empty_production_prefix_and_empty_package_list(self):
        manifest = self.script("cleanup-request.sh", PREFIX="", SHA="a" * 40,
                               RUN_ID="123", PACKAGES="")
        self.assertEqual(manifest["destination"], "production")
        self.assertEqual(manifest["purge_packages"], [])

    def test_removal_only_build_does_not_request_a_feed_update(self):
        manifest = self.script("build-publication.sh", DESTINATION="production",
                               SOURCE_SHA="a" * 40, SOURCE_RUN_ID="123", REMOVED="old")
        self.assertFalse(manifest["update_feed"])
        self.assertTrue(manifest["update_arch_pages"])
        self.assertEqual(manifest["purge_packages"], ["old"])

    def test_build_packages_and_results_are_assembled_for_testing(self):
        incoming = Path(self.temp.name) / "incoming"
        packages = incoming / "build-packages-x86_64"
        packages.mkdir(parents=True)
        (packages / "fixture-1_1.x86_64.xbps").write_bytes(b"binary")
        results = incoming / "build-results-x86_64"
        results.mkdir()
        (results / "results.tsv").write_text("fixture\t1\tok\n")
        manifest = self.script("build-publication.sh", DESTINATION="testing",
                               SOURCE_SHA="a" * 40, SOURCE_RUN_ID="123", REMOVED="")
        self.assertEqual(manifest["package_arches"], ["x86_64"])
        self.assertTrue(manifest["update_feed"])
        self.assertTrue(manifest["update_main_index"])
        self.assertEqual(validator.validate(self.root, "testing"), manifest)


if __name__ == "__main__":
    unittest.main()
