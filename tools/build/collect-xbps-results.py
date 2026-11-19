#!/usr/bin/env python3
"""Append rows for actual XBPS outputs belonging to successful source builds.

XBPS archives are tar files (possibly compressed) with XML metadata at
``./props.plist``. Python's plistlib parses that metadata after GNU tar
extracts it; both Python 3 and tar are runtime requirements.
"""

import argparse
import plistlib
from pathlib import Path
import re
import subprocess
import sys

PACKAGE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+._-]*$")
VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+~-]*$")
ARCH = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
STATUS = {"ok", "fail", "skip"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def source_rows(path: Path) -> dict[str, tuple[str, str]]:
    rows = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        fields = line.split("\t")
        require(len(fields) == 3, f"Malformed source result row {number}")
        package, version, status = fields
        require(bool(PACKAGE.fullmatch(package)), f"Unsafe package in source result row {number}")
        require(bool(VERSION.fullmatch(version)), f"Unsafe version in source result row {number}")
        require(status in STATUS, f"Invalid status in source result row {number}")
        prior = rows.get(package)
        current = (version, status)
        require(prior is None or prior == current,
                f"Conflicting source result rows for {package}")
        rows[package] = current
    return rows


def read_properties(path: Path) -> dict:
    result = subprocess.run(
        ["tar", "-xOf", str(path), "./props.plist"],
        check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    require(result.returncode == 0,
            f"Could not extract ./props.plist from candidate {path}: "
            f"{result.stderr.decode(errors='replace').strip()}")
    try:
        properties = plistlib.loads(result.stdout)
    except (plistlib.InvalidFileException, ValueError) as error:
        raise ValueError(f"Invalid ./props.plist in candidate {path}") from error
    require(isinstance(properties, dict), f"Invalid properties dictionary in {path}")
    return properties


def collect(results: Path, binpkgs: Path, arch: str) -> int:
    require(bool(ARCH.fullmatch(arch)), "Unsafe target architecture")
    sources = source_rows(results)
    successful = {pkg: version for pkg, (version, status) in sources.items() if status == "ok"}
    if not successful:
        return 0
    require(binpkgs.is_dir(), f"Missing XBPS output directory: {binpkgs}")

    version_markers = tuple(f"-{version}_" for version in set(successful.values()))
    appended = 0
    with results.open("a", encoding="utf-8") as output:
        for archive in sorted(binpkgs.rglob(f"*.{arch}.xbps")):
            if not any(marker in archive.name for marker in version_markers):
                continue
            require(not archive.is_symlink() and archive.is_file(),
                    f"Unsafe candidate XBPS path: {archive}")

            properties = read_properties(archive)
            required = ("pkgname", "pkgver", "version", "architecture", "sourcepkg")
            require(all(isinstance(properties.get(key), str) and properties[key]
                        for key in required), f"Missing/invalid XBPS metadata in {archive}")
            pkgname = properties["pkgname"]
            pkgver = properties["pkgver"]
            version_revision = properties["version"]
            binary_arch = properties["architecture"]
            sourcepkg = properties["sourcepkg"]
            require(bool(PACKAGE.fullmatch(pkgname)) and bool(PACKAGE.fullmatch(sourcepkg)),
                    f"Unsafe package metadata in {archive}")
            require(bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+~-]*_[A-Za-z0-9][A-Za-z0-9._+~-]*",
                                      version_revision)),
                    f"Unsafe version metadata in {archive}")
            version, revision = version_revision.rsplit("_", 1)
            require(bool(VERSION.fullmatch(version)) and bool(VERSION.fullmatch(revision)),
                    f"Unsafe version metadata in {archive}")
            require(binary_arch == arch, f"Wrong architecture metadata in candidate {archive}")
            require(pkgver == f"{pkgname}-{version_revision}",
                    f"Inconsistent pkgver metadata in {archive}")
            require(archive.name == f"{pkgver}.{arch}.xbps",
                    f"XBPS filename does not match metadata: {archive}")

            source_version = successful.get(sourcepkg)
            if source_version is None or version != source_version:
                continue
            if pkgname == sourcepkg:
                # The unchanged three-column source-template row already
                # represents this actual output package.
                continue
            output.write(f"{pkgname}\t{source_version}\tok\t{sourcepkg}\n")
            appended += 1
    return appended


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", required=True, type=Path)
    parser.add_argument("--binpkgs", required=True, type=Path)
    parser.add_argument("--arch", required=True)
    args = parser.parse_args()
    print(f"Recorded {collect(args.results, args.binpkgs, args.arch)} XBPS subpackage result(s)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        sys.exit(f"error: {error}")
