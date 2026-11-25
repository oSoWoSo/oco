"""Shared pack identity for update detection, planning and CI."""

from fnmatch import fnmatchcase
from pathlib import Path
import sys


def load_packs(root: Path) -> dict[str, list[str]]:
    listing = root / "config" / "autobump-packs.tsv"
    packs: dict[str, list[str]] = {}
    if listing.is_file():
        for number, line in enumerate(listing.read_text(encoding="utf-8").splitlines(), 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split()
            if len(fields) != 2:
                raise ValueError(f"malformed pack rule on line {number}: {line!r}")
            pack, pattern = fields
            packs.setdefault(pack, []).append(pattern)
    return packs


def pack_for(package: str, packs: dict[str, list[str]]) -> str | None:
    """The first matching pack wins; put full packs before their subsets."""
    return next((pack for pack, patterns in packs.items()
                 if any(fnmatchcase(package, pattern) for pattern in patterns)), None)


if __name__ == "__main__":
    print(pack_for(sys.argv[1], load_packs(Path.cwd())) or "")
