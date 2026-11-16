#!/usr/bin/env python3
"""Compute which OCO srcpkgs directories a VUR check branch must carry.

The VUR check pushes the templates changed by an OCO PR onto a single
ci-pr-<N> branch of the oSoWoSo/VUR fork so the official void-packages
build.yaml (build + xlint on ci-**) is run once for all of them.  A changed
template usually needs other OCO-only templates that are not yet part of
void-packages (their dependency stack) to even resolve at build time; the
official CI would otherwise fail with `host dependency 'X' does not exist!`.

This script turns a list of changed template names into the list of real
srcpkgs directories to overlay on that branch:

  * each changed name is resolved through srcpkgs symlink aliases to the
    real template directory;
  * the whole autobump pack of every changed template is carried when one of
    its members changed (packs are maintained as an interdependent unit);
  * every transitive build dependency of the carried set that exists in OCO
    but is absent from void-packages (VUR master) is added, so the branch is
    self-contained for the packages it actually tests.

Inputs (via argv):
  --root DIR        OCO checkout (contains srcpkgs/, .github/autobump-packs.tsv,
                    .github/autobump-dependencies.tsv)
  --changed LIST    space-separated changed template names (e.g. from the PR diff)
  --upstream FILE   file listing srcpkgs template dirs present on VUR master

Output: one real package directory name per line (sorted).
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

# Package-name shape used across the autobump tooling.
PACKAGE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+._-]*$")
ASSIGNMENT = re.compile(r"^(hostmakedepends|makedepends|depends)\s*(\+?=)\s*(.*)$")
CONSTRAINT = re.compile(r"[<>=]")


def strip_expansions(text: str) -> str:
    """Drop $(...), ${...} and `...` segments (kept in sync with autobump-batch.py)."""
    out: list[str] = []
    depth = 0
    for char in text:
        if char in "$`":
            depth += 1
            continue
        if depth:
            if char == ")":
                depth -= 1
            continue
        out.append(char)
    return "".join(out)


def assignment_value(lines: list[str], index: int) -> tuple[str, int]:
    """Return the value of the assignment at `index` and the next line index."""
    match = ASSIGNMENT.match(lines[index])
    value = match.group(3)
    position = index

    def unbalanced(text: str) -> bool:
        return text.count('"') % 2 == 1 or text.count("'") % 2 == 1

    while unbalanced(value) and position + 1 < len(lines):
        position += 1
        value += " " + lines[position].strip()
    return value, position


def template_dependencies(path: Path) -> set[str]:
    """Literal top-level dependency names of a template (no evaluation)."""
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    dependencies: set[str] = set()
    index = 0
    while index < len(lines):
        line = lines[index]
        if line.lstrip().startswith("#") or not ASSIGNMENT.match(line):
            index += 1
            continue
        value, index = assignment_value(lines, index)
        value = strip_expansions(value).replace('"', " ").replace("'", " ")
        value = value.split("#", 1)[0]
        for token in value.split():
            if token.startswith("-"):
                continue
            name = CONSTRAINT.split(token, 1)[0]
            if name and PACKAGE.fullmatch(name):
                dependencies.add(name)
        index += 1
    return dependencies


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--changed", required=True, help="space-separated changed template names")
    parser.add_argument("--upstream", type=Path, help="file with one template dir per line present on VUR master")
    args = parser.parse_args()

    root = args.root.resolve()
    srcpkgs = root / "srcpkgs"
    if not srcpkgs.is_dir():
        print(f"error: {srcpkgs} is not a directory", file=sys.stderr)
        return 2

    # Real template dirs and their alias map.
    real: set[str] = set()
    alias_of: dict[str, str] = {}
    try:
        for entry in sorted(srcpkgs.iterdir()):
            if entry.is_symlink():
                alias_of[entry.name] = os.readlink(entry)
            elif entry.is_dir() and (entry / "template").is_file():
                real.add(entry.name)
    except OSError as error:
        print(f"error: cannot read {srcpkgs}: {error}", file=sys.stderr)
        return 2

    def resolve(name: str) -> str | None:
        """Resolve a name to a real template dir, following aliases."""
        seen = 0
        while name in alias_of and seen < 8:
            name = alias_of[name]
            seen += 1
        return name if name in real else None

    # Templates present on VUR master (void-packages): not carried.
    upstream: set[str] = set()
    if args.upstream is not None and args.upstream.is_file():
        try:
            upstream = {line.strip() for line in args.upstream.read_text().splitlines() if line.strip()}
        except OSError as error:
            print(f"error: cannot read {args.upstream}: {error}", file=sys.stderr)
            return 2
    oco_only = real - upstream

    # Autobump packs: carry every member of any pack a changed template belongs to.
    packs: dict[str, set[str]] = {}
    pack_file = root / ".github" / "autobump-packs.tsv"
    try:
        for line in pack_file.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split()
            if len(fields) != 2:
                continue
            pack, member = fields
            packs.setdefault(pack, set()).add(member)
    except OSError as error:
        print(f"warning: cannot read {pack_file}: {error}", file=sys.stderr)

    # Changed templates -> real dirs.
    changed_names = args.changed.split()
    seeds: set[str] = set()
    for name in changed_names:
        resolved = resolve(name)
        if resolved is None:
            print(f"warning: changed template not in OCO srcpkgs: {name}", file=sys.stderr)
            continue
        seeds.add(resolved)

    # Any pack that has a seed as a real member: carry all its OCO-only members.
    seed_packs: set[str] = set()
    for pack, members in packs.items():
        if any(member in seeds for member in members):
            seed_packs.add(pack)
    carry: set[str] = set(seeds)
    for pack in seed_packs:
        for member in packs[pack]:
            if member in oco_only:
                carry.add(member)

    # Build dependency graph over all real templates: manifest first, literal
    # template parse as fallback for missing/empty entries. Only OCO-only
    # targets enter the closure below (upstream deps need not be carried).
    edges: dict[str, set[str]] = {name: set() for name in real}
    manifest: dict[str, set[str]] = {}
    dep_file = root / ".github" / "autobump-dependencies.tsv"
    try:
        for line in dep_file.read_text().splitlines():
            fields = line.split("\t")
            if len(fields) < 2 or fields[0].startswith("#"):
                continue
            manifest[fields[0]] = set(fields[2].split()) if len(fields) > 2 and fields[2] else set()
    except OSError as error:
        print(f"warning: cannot read {dep_file}: {error}", file=sys.stderr)

    for name in real:
        deps = manifest.get(name)
        if deps is None:
            try:
                deps = template_dependencies(srcpkgs / name / "template")
            except OSError:
                deps = set()
        for dep in deps:
            target = resolve(dep)
            if target is not None and target in real and target != name:
                edges[name].add(target)

    # Transitive closure of the carried set: a dependency is added only when
    # it is OCO-only (upstream packages are already buildable/resolvable), or
    # was itself an explicitly changed template.
    stack = list(carry)
    while stack:
        current = stack.pop()
        for dep in edges.get(current, ()):
            if dep in carry:
                continue
            if dep in oco_only or dep in seeds:
                carry.add(dep)
                stack.append(dep)

    for name in sorted(carry):
        print(name)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        sys.exit(f"error: {error}")