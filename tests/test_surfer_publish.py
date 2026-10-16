#!/usr/bin/env python3
"""Contract tests for the Surfer publication artifact validator."""

import importlib.util
import json
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
