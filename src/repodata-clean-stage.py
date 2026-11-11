#!/usr/bin/env python3
"""Drop the stage.plist member from an xbps repodata archive.

xbps-repo reads stage.plist when opening a local repository. If the previous
transaction aborted (e.g. xbps-rindex -a hit the "Inconsistent shlibs" path,
which refuses to merge stage into index.plist), a stale stage persists in the
repodata and is re-merged / re-committed on the next publish, blocking new
additions. Publishing must start from a clean stage.

This rewrites REPODATA without its stage.plist member, preserving the original
compression format and all other members. It is intentionally narrow: it never
touches index.plist / index-files.plist.

Usage:
    repodata-clean-stage.py REPODATA

Exit status 0 on success (including when there was no stage member to drop),
1 on a payload that is not a usable repodata, 2 on usage errors.
"""

from __future__ import annotations

import io
import os
import sys
import tarfile

TAR_MAGIC_OFFSET = 257
TAR_MAGIC = b"ustar"

STAGE_MEMBER = "stage.plist"

USAGE = "Usage: %s REPODATA\n"


class RepodataError(Exception):
    """REPODATA is not a usable xbps repodata archive."""


def _zstd_decompress(path: str) -> bytes:
    try:
        import subprocess
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
        import subprocess
        p = subprocess.run(
            ["zstd", "-c"], input=data, capture_output=True, check=True
        )
    except FileNotFoundError:
        sys.stderr.write("error: `zstd` CLI not found for re-compression\n")
        sys.exit(2)
    return p.stdout


def detect_format(path: str) -> str:
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


def _read_archive(path: str) -> tuple[str, list[tuple[tarfile.TarInfo, bytes]]]:
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
            f"not a recognised archive; first bytes: {head[:16].hex()} | {printable}"
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
    except SystemExit as e:
        raise RepodataError(f"cannot decode {fmt} archive (zstd CLI problem)") from e

    names = [m.name for m, _ in members]
    if "index.plist" not in names:
        raise RepodataError(
            "archive has no index.plist; not an xbps repodata "
            f"(members: {', '.join(names) or '(none)'})"
        )
    return fmt, members


def _write_archive(path: str, fmt: str, members: list[tuple[tarfile.TarInfo, bytes]]) -> None:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:") as tf:
        for m, data in members:
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

    tmp = path + ".tmp"
    try:
        with open(tmp, "wb") as f:
            f.write(out_bytes)
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main() -> int:
    if len(sys.argv) != 2:
        sys.stderr.write(USAGE % sys.argv[0])
        return 2
    repodata = sys.argv[1]

    try:
        fmt, members = _read_archive(repodata)
    except RepodataError as e:
        sys.stderr.write(f"error: {repodata}: {e}\n")
        return 1

    stage_members = [(m, d) for m, d in members if m.name == STAGE_MEMBER]
    if not stage_members:
        print("  no stage.plist present; nothing to do")
        return 0

    kept = [km for km in members if km[0].name != STAGE_MEMBER]
    print(f"  dropped stale stage.plist ({len(stage_members)} member)")
    _write_archive(repodata, fmt, kept)
    return 0


if __name__ == "__main__":
    sys.exit(main())