#!/usr/bin/env python3
"""Validate a surfer-publication artifact before any remote writes."""

import argparse
import json
import re
from pathlib import Path

ARCHES = {"x86_64", "x86_64-musl", "aarch64", "aarch64-musl"}
FIELDS = {
    "schema_version", "destination", "source_sha", "source_run_id",
    "package_arches", "result_arches", "purge_packages",
    "update_arch_pages", "update_feed", "update_main_index",
}
PACKAGE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9+._-]*\Z")
SHA = re.compile(r"[0-9a-fA-F]{40}\Z")
RUN_ID = re.compile(r"[0-9]+\Z")


class RequestError(ValueError):
    """Invalid or unsafe publication request."""


def _fail(message):
    raise RequestError(message)


def validate(root, destination):
    root = Path(root)
    if destination not in {"production", "testing"}:
        _fail("unsupported workflow destination")
    if not root.is_dir() or root.is_symlink():
        _fail("artifact root must be a real directory")
    for path in root.rglob("*"):
        if path.is_symlink():
            _fail(f"symlink is not allowed: {path.relative_to(root)}")
        if not path.is_file() and not path.is_dir():
            _fail(f"unsupported artifact entry: {path.relative_to(root)}")
    manifest_path = root / "manifest.json"
    if not manifest_path.is_file():
        _fail("missing manifest.json")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        _fail(f"invalid manifest JSON: {exc}")
    if not isinstance(manifest, dict) or set(manifest) != FIELDS:
        _fail("manifest must contain exactly the documented fields")
    if type(manifest["schema_version"]) is not int or manifest["schema_version"] != 1:
        _fail("unsupported schema_version")
    if manifest["destination"] != destination:
        _fail("artifact destination does not match workflow input")
    if not isinstance(manifest["source_sha"], str) or not SHA.fullmatch(manifest["source_sha"]):
        _fail("source_sha must be a 40-character hexadecimal SHA")
    if not isinstance(manifest["source_run_id"], str) or not RUN_ID.fullmatch(manifest["source_run_id"]):
        _fail("source_run_id must be a decimal run ID")

    def arches(key):
        values = manifest[key]
        if not isinstance(values, list) or any(not isinstance(v, str) or v not in ARCHES for v in values):
            _fail(f"{key} must be an array of supported architectures")
        if len(values) != len(set(values)):
            _fail(f"{key} contains duplicate architectures")
        return values

    package_arches = arches("package_arches")
    result_arches = arches("result_arches")
    purges = manifest["purge_packages"]
    if not isinstance(purges, list) or any(not isinstance(v, str) or not PACKAGE_NAME.fullmatch(v) for v in purges):
        _fail("purge_packages contains an unsafe package name")
    if len(purges) != len(set(purges)):
        _fail("purge_packages contains duplicates")
    for key in ("update_arch_pages", "update_feed", "update_main_index"):
        if type(manifest[key]) is not bool:
            _fail(f"{key} must be boolean")
    if manifest["update_feed"] and not result_arches:
        _fail("feed update requires result_arches")

    expected_files = {"manifest.json"}
    for arch in package_arches:
        folder = root / "packages" / arch
        if not folder.is_dir():
            _fail(f"missing package directory for {arch}")
        packages = [p for p in folder.iterdir() if p.is_file()]
        if not packages:
            _fail(f"no packages supplied for declared architecture {arch}")
        for package in packages:
            if not package.name.endswith(".xbps"):
                _fail(f"invalid package payload name: {package.name}")
            expected_files.add(package.relative_to(root).as_posix())
    for arch in result_arches:
        result = root / "results" / f"{arch}.tsv"
        if not result.is_file():
            _fail(f"missing results/{arch}.tsv")
        expected_files.add(result.relative_to(root).as_posix())
    if purges:
        purge_file = root / "purge-packages.txt"
        if not purge_file.is_file():
            _fail("missing purge-packages.txt")
        try:
            listed = purge_file.read_text(encoding="utf-8").split()
        except UnicodeError as exc:
            _fail(f"invalid purge package list: {exc}")
        if listed != purges:
            _fail("purge-packages.txt must exactly match manifest purge_packages")
        expected_files.add("purge-packages.txt")
    actual_files = {p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file()}
    if actual_files != expected_files:
        _fail(f"payload files do not match manifest (extra={sorted(actual_files - expected_files)}, missing={sorted(expected_files - actual_files)})")
    return manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact")
    parser.add_argument("--destination", required=True)
    args = parser.parse_args()
    try:
        manifest = validate(args.artifact, args.destination)
    except RequestError as exc:
        parser.error(str(exc))
    print(json.dumps(manifest, sort_keys=True))


if __name__ == "__main__":
    main()
