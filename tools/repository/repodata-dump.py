#!/usr/bin/env python3
"""Dump an xbps repodata index as TSV.

Reads one plist member of an xbps repodata tar archive and prints one TSV
line per entry, with a header line first. Used by compare-community.sh to
build its persistent package database.

Usage:
    repodata-dump.py [--index NAME] REPODATA

Options:
    --index NAME   plist member to read (default: index.plist)

Exit status 0 on success (output may be empty if the index is empty),
2 on usage/format errors, 1 on I/O or parse failure.
"""

from __future__ import annotations

import argparse
import io
import plistlib
import subprocess
import sys
import tarfile

# Keys rendered as columns. `pkgname` is the top-level index key, the rest
# are looked up in the per-package dict. `pkgver` is already
# "Name-version_revision" upstream, so filenames never need parsing.
COLUMNS = (
    "pkgname",
    "pkgver",
    "architecture",
    "filename-size",
    "installed_size",
    "sourcepkg",
    "homepage",
    "maintainer",
    "license",
    "short_desc",
)

# Keys that must not reach json.dumps in the orchestrator; `index-meta.plist`
# holds the public key as bytes, which raises
# TypeError: Object of type bytes is not JSON serializable.
BYTES_KEYS = frozenset({"public-key"})


def _zstd_decompress(path: str) -> bytes:
    # Python's stdlib lacks zstd before 3.14, and xbps writes zstd by
    # default. Shell out to the `zstd` CLI -- universally available via
    # the `zstd` package on every relevant distro.
    #
    # NB: `zstd -dc` needs a REAL FILE. A pipe or process substitution
    # fails with "zstd: can't stat /dev/fd/63", so decompress to bytes
    # first and feed those to tarfile.
    try:
        return subprocess.check_output(["zstd", "-dc", "--", path])
    except FileNotFoundError:
        sys.stderr.write(
            "error: zstd repodata detected but the `zstd` CLI is not "
            "installed (install the zstd package)\n"
        )
        sys.exit(2)
    except subprocess.CalledProcessError as e:
        sys.stderr.write(f"error: zstd decompression failed: {e}\n")
        sys.exit(1)


def open_tar_any(path: str) -> tarfile.TarFile:
    """Open a repodata tar with any of the compressions xbps may use."""
    with open(path, "rb") as f:
        magic = f.read(4)
    if magic[:2] == b"\x1f\x8b":
        return tarfile.open(path, mode="r:gz")
    if magic[:3] == b"BZh":
        return tarfile.open(path, mode="r:bz2")
    if magic[:4] == b"\x28\xb5\x2f\xfd":
        return tarfile.open(fileobj=io.BytesIO(_zstd_decompress(path)), mode="r:")
    return tarfile.open(path, mode="r:")


def read_index(path: str, member: str) -> dict:
    """Return the parsed plist member as a dict."""
    try:
        with open_tar_any(path) as tf:
            for m in tf.getmembers():
                if m.name == member and m.isfile():
                    f = tf.extractfile(m)
                    if f is None:
                        sys.stderr.write(f"error: cannot read {member}\n")
                        sys.exit(1)
                    data = plistlib.loads(f.read())
                    if not isinstance(data, dict):
                        sys.stderr.write(f"error: {member} is not a dict\n")
                        sys.exit(1)
                    return data
    except (tarfile.TarError, OSError, plistlib.InvalidFileException) as e:
        sys.stderr.write(f"error: {e}\n")
        sys.exit(1)
    sys.stderr.write(f"error: no {member} in repodata\n")
    sys.exit(1)
    return {}  # unreachable, keeps type checkers quiet


def render(value: object) -> str:
    """Render one cell: bytes safely, everything else as flat text.

    A literal tab or newline would break the one-entry-per-line TSV
    contract, so both collapse to a space.
    """
    if isinstance(value, bytes):
        return f"<{len(value)} bytes>"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (list, tuple)):
        value = " ".join(str(v) for v in value)
    if value is None:
        return ""
    text = str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ")
    return text.strip()


def main() -> int:
    _ap = argparse.ArgumentParser(add_help=True, description=__doc__)
    _ap.add_argument("repodata", help="path to a repodata tar archive")
    _ap.add_argument(
        "--index",
        default="index.plist",
        help="plist member to read (default: index.plist)",
    )
    args = _ap.parse_args()

    index = read_index(args.repodata, args.index)

    print("\t".join(COLUMNS))
    for pkgname in sorted(index):
        entry = index[pkgname]
        if not isinstance(entry, dict):
            entry = {}
        row = [pkgname] + [render(entry.get(c)) for c in COLUMNS if c != "pkgname"]
        print("\t".join(row))
    return 0


if __name__ == "__main__":
    sys.exit(main())
