#!/usr/bin/env python3
"""Remove package entries from an xbps repodata file.

The repodata file is a (possibly gzip-compressed) tar archive containing
`index.plist` and optionally `index-files.plist` and `index-meta.plist`,
all in Apple XML plist format with package names as top-level keys.

Usage:
    repodata-strip.py REPODATA NAME [NAME...]
    repodata-strip.py --check REPODATA

`--check` only validates the payload (magic bytes + readable tar + a member
called index.plist) and touches nothing. It exists because the transport that
produces REPODATA (the Surfer CLI) exits 0 even when it writes an error page
or a truncated body to stdout, so `ocoman` needs a cheap way to tell a real
index from junk before trusting it.

Exit status 0 on success (including no-op when no listed name was present),
1 on a payload that is not a usable repodata, 2 on usage errors.
"""

from __future__ import annotations

import io
import os
import plistlib
import subprocess
import sys
import tarfile

INDEX_FILES = {"index.plist", "index-files.plist"}
# tar(1) writes "ustar" at offset 257 for the ustar/gnu/pax variants xbps uses.
TAR_MAGIC_OFFSET = 257
TAR_MAGIC = b"ustar"

USAGE = "Usage: %s [--check] REPODATA [NAME...]\n"


class RepodataError(Exception):
    """REPODATA is not a usable xbps repodata archive."""


def _zstd_decompress(path: str) -> bytes:
    # Raise, do not sys.exit: read_archive() turns this into a RepodataError so
    # a truncated download is reported the same way as any other junk payload.
    try:
        return subprocess.check_output(["zstd", "-dc", "--", path])
    except FileNotFoundError:
        raise RepodataError(
            "zstd repodata detected but the `zstd` CLI is not installed "
            "(apt install zstd)"
        ) from None
    except subprocess.CalledProcessError as e:
        raise RepodataError(f"zstd decompression failed (truncated?) : {e}") from None


def _zstd_compress(data: bytes) -> bytes:
    try:
        p = subprocess.run(
            ["zstd", "-c"], input=data, capture_output=True, check=True
        )
    except FileNotFoundError:
        sys.stderr.write("error: `zstd` CLI not found for re-compression\n")
        sys.exit(2)
    return p.stdout


def detect_format(path: str) -> str:
    """Returns 'gz', 'bz2', 'zstd', or 'tar' (uncompressed)."""
    with open(path, "rb") as f:
        magic = f.read(6)
    if magic[:2] == b"\x1f\x8b":
        return "gz"
    if magic[:3] == b"BZh":
        return "bz2"
    if magic[:4] == b"\x28\xb5\x2f\xfd":
        return "zstd"
    return "tar"


def _looks_like_tar(path: str) -> bool:
    try:
        with open(path, "rb") as f:
            f.seek(TAR_MAGIC_OFFSET)
            return f.read(5) == TAR_MAGIC
    except OSError:
        return False


def open_tar_any(path: str, fmt: str) -> tarfile.TarFile:
    if fmt == "gz":
        return tarfile.open(path, mode="r:gz")
    if fmt == "bz2":
        return tarfile.open(path, mode="r:bz2")
    if fmt == "zstd":
        return tarfile.open(fileobj=io.BytesIO(_zstd_decompress(path)), mode="r:")
    return tarfile.open(path, mode="r:")


def read_archive(path: str) -> tuple[str, list[tuple[tarfile.TarInfo, bytes]]]:
    """Validate and fully read REPODATA.

    Raises RepodataError -- never a bare tarfile/zstd traceback -- so callers
    can tell "the download gave me junk" apart from "this tool has a bug".
    """
    if not os.path.isfile(path):
        raise RepodataError(f"not a file: {path}")
    if os.path.getsize(path) == 0:
        raise RepodataError("file is empty (0 bytes); the download produced no payload")

    fmt = detect_format(path)
    if fmt == "tar" and not _looks_like_tar(path):
        with open(path, "rb") as f:
            head = f.read(64)
        printable = "".join(chr(b) if 32 <= b < 127 else "." for b in head)
        raise RepodataError(
            f"not a recognised archive (no gzip/bzip2/zstd magic, no tar header); "
            f"first bytes: {head[:16].hex()} | {printable}"
        )

    try:
        members: list[tuple[tarfile.TarInfo, bytes]] = []
        with open_tar_any(path, fmt) as tf:
            for m in tf.getmembers():
                extracted = tf.extractfile(m)
                data = extracted.read() if extracted is not None else b""
                members.append((m, data))
    except RepodataError:
        raise
    except tarfile.TarError as e:
        raise RepodataError(f"truncated or corrupt {fmt} tar archive: {e}") from e
    except OSError as e:
        raise RepodataError(f"cannot read {path}: {e}") from e
    except SystemExit as e:  # e.g. missing zstd CLI from the helpers
        raise RepodataError(f"cannot decode {fmt} archive (zstd CLI problem)") from e

    return fmt, members


def _index_entries(members) -> dict[str, dict]:
    """Parse every index plist member into {member name: dict}."""
    parsed = {}
    for m, data in members:
        if m.name not in INDEX_FILES or not m.isfile():
            continue
        try:
            idx = plistlib.loads(data)
        except Exception as e:
            raise RepodataError(f"failed to parse {m.name}: {e}") from e
        if isinstance(idx, dict):
            parsed[m.name] = idx
    return parsed


def check(path: str) -> int:
    """--check: validate only, print a one-line verdict, return 0."""
    try:
        fmt, members = read_archive(path)
        indexes = _index_entries(members)
        if not indexes:
            names = ", ".join(m.name for m, _ in members) or "(none)"
            raise RepodataError(f"archive has no readable index.plist; members: {names}")
    except RepodataError as e:
        sys.stderr.write(f"error: {path}: {e}\n")
        return 1
    total = len(set().union(*(set(d) for d in indexes.values())))
    print(f"  {path}: ok ({fmt} archive, {len(members)} members, {total} package names)")
    return 0


def main() -> int:
    argv = sys.argv[1:]
    check_only = False
    if argv and argv[0] in ("-c", "--check"):
        check_only = True
        argv = argv[1:]

    if len(argv) < 1:
        sys.stderr.write(USAGE % sys.argv[0])
        return 2
    repodata = argv[0]

    if check_only:
        if len(argv) > 1:
            sys.stderr.write(USAGE % sys.argv[0])
            return 2
        return check(repodata)

    drop = set(argv[1:])
    if not drop:
        return 0

    try:
        fmt, members = read_archive(repodata)
        indexes = _index_entries(members)
    except RepodataError as e:
        sys.stderr.write(f"error: {repodata}: {e}\n")
        return 1

    total_removed = 0
    rewritten: list[tuple[tarfile.TarInfo, bytes]] = []
    for m, data in members:
        if m.name in indexes:
            idx = indexes[m.name]
            removed = [k for k in list(idx) if k in drop]
            for k in removed:
                del idx[k]
            if removed:
                total_removed += len(removed)
                print(
                    f"  {m.name}: removed {len(removed)} entries "
                    f"({', '.join(removed)})"
                )
                data = plistlib.dumps(idx, fmt=plistlib.FMT_XML)
                m.size = len(data)
        rewritten.append((m, data))

    if total_removed == 0:
        print("  no matching entries in repodata; nothing to do")
        return 0

    # Build the new (uncompressed) tar in memory, then re-apply the
    # original compression so the on-wire format is preserved.
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:") as tf:
        for m, data in rewritten:
            tf.addfile(m, io.BytesIO(data))
    raw = buf.getvalue()

    if fmt == "zstd":
        out_bytes = _zstd_compress(raw)
    elif fmt == "gz":
        import gzip
        out_bytes = gzip.compress(raw)
    elif fmt == "bz2":
        import bz2
        out_bytes = bz2.compress(raw)
    else:
        out_bytes = raw

    tmp = repodata + ".tmp"
    try:
        with open(tmp, "wb") as f:
            f.write(out_bytes)
        os.replace(tmp, repodata)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return 0


if __name__ == "__main__":
    sys.exit(main())