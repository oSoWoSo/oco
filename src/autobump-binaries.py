#!/usr/bin/env python3
"""Capture only newly produced XBPS binaries for an autobump PR matrix job."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys

ARCHES = {"x86_64", "x86_64-musl", "aarch64", "aarch64-musl"}
HOSTS = {"x86_64", "x86_64-musl", "aarch64", "aarch64-musl"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def package_files(root: Path):
    if not root.is_dir():
        raise ValueError(f"Missing package output directory: {root}")
    for path in sorted(root.rglob("*.xbps")):
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Unexpected package path: {path}")
        yield path.relative_to(root).as_posix(), path


def main():
    p = argparse.ArgumentParser()
    p.add_argument("operation", choices=["snapshot", "collect"])
    p.add_argument("--binpkgs", required=True, type=Path)
    p.add_argument("--snapshot", required=True, type=Path)
    p.add_argument("--output", type=Path)
    p.add_argument("--arch")
    p.add_argument("--host")
    p.add_argument("--results", type=Path)
    a = p.parse_args()

    if a.operation == "snapshot":
        state = {name: sha256(path) for name, path in package_files(a.binpkgs)}
        a.snapshot.parent.mkdir(parents=True, exist_ok=True)
        a.snapshot.write_text(json.dumps(state, sort_keys=True), encoding="utf-8")
        print(f"Recorded {len(state)} existing XBPS binaries")
        return

    if a.arch not in ARCHES or a.host not in HOSTS or a.output is None:
        raise ValueError("Invalid target arch/host or missing --output")
    before = json.loads(a.snapshot.read_text(encoding="utf-8"))
    a.output.mkdir(parents=True, exist_ok=True)
    pkg_dir = a.output / "packages"
    pkg_dir.mkdir(parents=True, exist_ok=True)
    files = []
    for name, path in package_files(a.binpkgs):
        if not name.endswith(f".{a.arch}.xbps"):
            continue
        checksum = sha256(path)
        if before.get(name) == checksum:
            continue
        base = path.name
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+~-]*\.xbps", base):
            raise ValueError(f"Unexpected XBPS filename: {base}")
        destination = pkg_dir / base
        if destination.exists():
            raise ValueError(f"Conflicting package basenames: {base}")
        shutil.copy2(path, destination)
        if sha256(destination) != checksum:
            raise ValueError(f"Copied package checksum mismatch: {base}")
        files.append({"name": base, "sha256": checksum})

    if not files:
        raise ValueError(f"No newly built .{a.arch}.xbps files to publish")
    if a.results is None or not a.results.is_file():
        raise ValueError("Missing build results.tsv")
    results_digest = sha256(a.results)
    shutil.copyfile(a.results, a.output / "results.tsv")
    manifest = {"arch": a.arch, "host": a.host, "files": files, "results_sha256": results_digest}
    (a.output / "manifest.json").write_text(
        json.dumps(manifest, sort_keys=True, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Staged {len(files)} new binaries for {a.arch} on {a.host}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, json.JSONDecodeError) as error:
        sys.exit(f"error: {error}")
