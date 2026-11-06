#!/usr/bin/env python3
"""Plan pack-aware autobumps using XBPS-resolved build dependencies.

The pack is the upstream-update detection boundary. Only changed packages
and their direct build-dependent consumers are revised; XBPS resolves the
dependency graph without requiring a full build.

Usage:
    autobump-batch.py plan TARGET --output FILE [--repo-root DIR] [--force]
    autobump-batch.py apply --plan FILE [--repo-root DIR]

The plan file is TSV, one row per changed package:

    <package>\t<version>\t<kind>\t<order>

<kind> is "version" for an upstream version bump and "revision" for a
revision-only bump, <version> is the new upstream version (empty for a
revision bump) and <order> is the XBPS-resolved dependency order. An empty
plan file means there is nothing to bump.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import fnmatch
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys


PACKAGE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+._-]*$")
VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+~-]*$")
ASSIGNMENT = re.compile(r"^(hostmakedepends|makedepends|depends)\s*(\+?=)\s*(.*)$")
CONSTRAINT = re.compile(r"[<>=]")


def strip_expansions(text: str) -> str:
    """Drop $(...), ${...} and `...` segments.

    Templates compute some dependency lists at build time. Evaluating them
    here is not possible (they need a build environment), and a partially
    expanded list is worse than none: it would connect packages that are
    not related. The literal tokens around them are kept.
    """
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
    """Return the value of the assignment at `index` and the next line index.

    A quoted value may span several lines (nwg-shell lists two dozen
    dependencies that way), so the value is read until the quotes balance.
    """
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
    """Return the literal package names a template depends on.

    Only top-level assignments count: an indented `depends=` belongs to a
    subpackage function, and there it refers to the template's own source
    package rather than to another package.
    """
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


def template_is_metapackage(path: Path) -> bool:
    """Return whether a template builds nothing (a metapackage).

    A metapackage ships no binaries, so a changed dependency does not make
    it stale; bumping its revision would only republish the same package.
    """
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("metapackage="):
            return line.split("=", 1)[1].strip().strip('"') == "yes"
    return False


class Repository:
    """The template tree of one checkout."""

    def __init__(self, root: Path, xbps_src: Path | None = None):
        self.root = root
        self.xbps_src = xbps_src
        self.templates: dict[str, Path] = {}
        self.aliases: dict[str, str] = {}
        for entry in sorted((root / "srcpkgs").iterdir()):
            if entry.is_symlink():
                self.aliases[entry.name] = os.readlink(entry)
            elif entry.is_dir() and (entry / "template").is_file():
                self.templates[entry.name] = entry / "template"

    def resolve(self, name: str) -> str | None:
        """Map an alias to the real package it points at."""
        target = self.aliases.get(name)
        if target is None:
            return None
        return target if target in self.templates else None

    def pack_members(self, package: str) -> set[str]:
        """Return real templates in any configured pack containing package."""
        listing = self.root / ".github" / "autobump-packs.tsv"
        if not listing.is_file():
            return set()
        packs: dict[str, list[str]] = {}
        for number, line in enumerate(listing.read_text(encoding="utf-8").splitlines(), 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split()
            if len(fields) != 2:
                raise ValueError(f"malformed pack rule on line {number}: {line!r}")
            pack, pattern = fields
            packs.setdefault(pack, []).append(pattern)
        matched = {
            pack for pack, patterns in packs.items()
            if any(fnmatch.fnmatchcase(package, pattern) for pattern in patterns)
        }
        return {
            name for name in self.templates
            if any(
                fnmatch.fnmatchcase(name, pattern)
                for pack in matched
                for pattern in packs[pack]
            )
        }

    def dependency_manifest(self) -> Path:
        return self.root / ".github" / "autobump-dependencies.tsv"

    def _template_hash(self, package: str) -> str:
        return hashlib.sha256(self.templates[package].read_bytes()).hexdigest()

    def _load_manifest(self) -> dict[str, tuple[str, set[str]]]:
        path = self.dependency_manifest()
        if not path.exists():
            return {}
        rows: dict[str, tuple[str, set[str]]] = {}
        lines = path.read_text(encoding="utf-8").splitlines()
        if not lines or lines[0] != "# autobump-dependencies-v1":
            raise ValueError(f"invalid dependency manifest header: {path}")
        for number, line in enumerate(lines[1:], 2):
            fields = line.split("\t")
            if len(fields) != 3:
                raise ValueError(f"malformed dependency manifest row {number}: {line!r}")
            package, digest, dependencies = fields
            if not PACKAGE.fullmatch(package) or not re.fullmatch(r"[0-9a-f]{64}", digest):
                raise ValueError(f"invalid dependency manifest row {number}: {line!r}")
            if package in rows:
                raise ValueError(f"duplicate dependency manifest package on line {number}: {package}")
            deps = dependencies.split() if dependencies else []
            if any(not PACKAGE.fullmatch(dep) for dep in deps):
                raise ValueError(f"invalid dependency name on manifest line {number}")
            if deps != sorted(set(deps)):
                raise ValueError(f"dependencies are not unique and sorted on manifest line {number}")
            rows[package] = (digest, set(deps))
        return rows

    def _write_manifest(self, rows: dict[str, tuple[str, set[str]]]) -> None:
        path = self.dependency_manifest()
        lines = ["# autobump-dependencies-v1"]
        for package in sorted(rows):
            digest, dependencies = rows[package]
            lines.append(f"{package}\t{digest}\t{' '.join(sorted(dependencies))}")
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def dependencies(self) -> dict[str, set[str]]:
        """Return build dependency edges between real packages."""
        edges: dict[str, set[str]] = {}
        for name, template in self.templates.items():
            resolved: set[str] = set()
            for dependency in self._build_dependencies(name, template):
                target = self.resolve(dependency) or dependency
                if target in self.templates and target != name:
                    resolved.add(target)
            edges[name] = resolved
        return edges

    def cached_dependencies(self) -> dict[str, set[str]]:
        """Load or incrementally refresh the complete real-template graph."""
        manifest = self._load_manifest()
        current: dict[str, tuple[str, set[str]]] = {}
        for name, (digest, dependencies) in manifest.items():
            if name not in self.templates:
                continue
            canonical = {self.resolve(dep) or dep for dep in dependencies}
            canonical.discard(name)
            canonical.intersection_update(self.templates)
            current[name] = (digest, canonical)
        for name, template in sorted(self.templates.items()):
            digest = self._template_hash(name)
            cached = current.get(name)
            if cached is not None and cached[0] == digest:
                continue
            try:
                resolved = self._build_dependencies(name, template)
            except (OSError, RuntimeError) as error:
                print(f"warning: dependency resolution failed for {name}; using template parser: {error}", file=sys.stderr)
                resolved = template_dependencies(template)
            dependencies = set()
            for dependency in resolved:
                target = self.resolve(dependency) or dependency
                if target in self.templates and target != name:
                    dependencies.add(target)
            current[name] = (digest, dependencies)
        self._write_manifest(current)
        return {name: set(row[1]) for name, row in current.items()}

    def _build_dependencies(self, package: str, template: Path) -> set[str]:
        """Resolve dependencies with XBPS when available, otherwise parse literals."""
        if self.xbps_src is None:
            return template_dependencies(template)
        command = [str(self.xbps_src), "show-build-deps", package]
        if os.geteuid() == 0:
            # xbps-src deliberately refuses root. The autobump job runs as root
            # in its container, while the prepared checkout belongs to builder.
            command = ["sudo", "-Eu", "builder", *command]
        result = subprocess.run(
            command,
            cwd=self.xbps_src.parent,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode:
            message = result.stderr.strip() or result.stdout.strip()
            raise RuntimeError(
                f"xbps-src show-build-deps failed for {package}: {message}"
            )
        return {
            dependency
            for line in result.stdout.splitlines()
            for dependency in line.split()
            if PACKAGE.fullmatch(dependency)
        }


    def blacklist(self) -> set[str]:
        """Return the packages that are excluded from upstream bumps."""
        listing = self.root / "src" / "autobump-blacklist"
        packages = set()
        for line in listing.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                packages.add(line)
        return packages


def component(graph: dict[str, set[str]], start: str) -> set[str]:
    """Return the connected component of `start`.

    The graph is walked in both directions: a package that depends on the
    target belongs to the same batch, and so does a package the target
    depends on. That is what keeps a desktop environment (COSMIC, nwg-shell,
    the Hyprland family) in one pull request instead of one request per
    component member.
    """
    neighbours: dict[str, set[str]] = {}
    for package, dependencies in graph.items():
        for dependency in dependencies:
            neighbours.setdefault(package, set()).add(dependency)
            neighbours.setdefault(dependency, set()).add(package)

    seen = {start}
    pending = [start]
    while pending:
        current = pending.pop()
        for neighbour in neighbours.get(current, ()):
            if neighbour not in seen:
                seen.add(neighbour)
                pending.append(neighbour)
    return seen


def _bulk_sortdeps_edges(graph: dict[str, set[str]], packages: set[str]) -> list[str]:
    """Emit the tsort input `xbps-src sort-dependencies` would build.

    Mirrors `bulk_sortdeps` in common/xbps-src/shutils/bulk.sh: walk the
    given packages and, for each one, emit a `pkg dep` relation for every
    build dependency that is part of the batch; a package without in-batch
    dependencies gets a self relation so it still appears in the output.
    The CI build passes the batch in alphabetical order, so the packages
    are walked alphabetically.  `show-build-deps` reports the dependencies
    in template order, which is lost once they are collapsed into a set,
    so the dependencies are walked alphabetically; for unambiguous graphs
    like the Hyprland family this reproduces the real build order.
    """
    relations: list[str] = []
    for package in sorted(packages):
        dependencies = sorted(graph.get(package, ()) & packages)
        for dependency in dependencies:
            relations.append(f"{package} {dependency}")
        if not dependencies:
            relations.append(f"{package} {package}")
    return relations


def build_order(graph: dict[str, set[str]], packages: set[str]) -> list[str]:
    """Order the packages so every dependency precedes its dependents.

    This mirrors the order `xbps-src sort-dependencies` produces for the
    build: `bulk_sortdeps` feeds the `pkg dep` relations to `tsort`, whose
    output is then reversed with `tac`.  Reusing the same `tsort` binary (a
    coreutils dependency the builder image already has) makes the planned
    order match the real build order instead of a home-grown traversal.
    A dependency cycle is broken the same way tsort breaks it, by removing
    one relation.
    """
    relations = "\n".join(_bulk_sortdeps_edges(graph, packages)) + "\n"
    result = subprocess.run(
        ["tsort"],
        input=relations,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "tsort failed to order the batch: "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
    return result.stdout.split()[::-1]


def detect_update(root: Path, package: str) -> str | None:
    """Return the newer upstream version of a package, or None."""
    detector = root / ".github" / "scripts" / "detect-update.sh"
    result = subprocess.run(
        ["bash", str(detector), package, str(root)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode >= 2:
        raise RuntimeError(
            f"update detection failed for {package} "
            f"(rc={result.returncode}): {result.stderr.strip()}"
        )
    output = result.stdout.strip()
    if not output:
        return None
    fields = output.split()
    if len(fields) != 3 or fields[0] != package:
        raise ValueError(f"unexpected detection output for {package}: {output!r}")
    version = fields[2]
    if not VERSION.fullmatch(version):
        raise ValueError(f"unsafe version for {package}: {version!r}")
    return version


def detect_updates(root: Path, packages: list[str]) -> dict[str, str]:
    """Return the packages that have a newer upstream release.

    Detection is a network call per package, so the candidates are checked
    in parallel; a batch of thirty packages must not take thirty round trips
    in series.
    """
    if not packages:
        return {}

    versions: dict[str, str] = {}
    with ThreadPoolExecutor(max_workers=min(8, len(packages))) as pool:
        futures = {
            pool.submit(detect_update, root, package): package for package in packages
        }
        for future in as_completed(futures):
            package = futures[future]
            version = future.result()
            if version:
                versions[package] = version
    return versions


def apply_version_bump(root: Path, package: str, version: str) -> None:
    """Bump a template to an upstream version through the shared helper."""
    helper = root / ".github" / "scripts" / "bump-template.sh"
    result = subprocess.run(
        ["bash", str(helper), package, version, str(root)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"could not bump {package} to {version}: {result.stderr.strip()}"
        )


def apply_revision_bump(root: Path, package: str) -> None:
    """Raise the revision of a template through the shared helper."""
    helper = root / ".github" / "scripts" / "bump-revision.sh"
    result = subprocess.run(
        ["bash", str(helper), package, str(root)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"could not raise the revision of {package}: {result.stderr.strip()}"
        )


def plan_batch(
    root: Path,
    target: str,
    *,
    force: bool,
    xbps_src: Path | None = None,
) -> tuple[list[tuple[str, str, str, int]], list[str]]:
    """Plan a singleton target or configured pack and direct consumer revisions.

    Pack plans detect updates only among configured members and use the cached
    complete graph for reverse consumers. Ungrouped targets skip resolution.
    """
    repository = Repository(root, xbps_src=xbps_src)
    if target in repository.aliases:
        if not force:
            raise ValueError(f"target is a symlink alias, not bumpable: {target}")
        target = repository.resolve(target)
        if target is None:
            raise ValueError(f"target is a symlink alias to an unknown package: {target}")
    if target not in repository.templates:
        raise ValueError(f"target is not a real package template: {target}")

    excluded = repository.blacklist()
    if force:
        excluded.discard(target)
    if target in excluded:
        raise ValueError(f"target is in src/autobump-blacklist: {target}")
    pack = repository.pack_members(target)
    if not pack:
        updated = detect_updates(root, [target])
        if target not in updated:
            return [], [target]
        row = (target, updated[target], "version", 0)
        return [row], [target]

    graph = repository.cached_dependencies()
    candidates = sorted(pack - excluded)
    updated = detect_updates(root, candidates)
    if not updated:
        return [], candidates

    reverse: dict[str, set[str]] = {}
    for package, dependencies in graph.items():
        for dependency in dependencies:
            reverse.setdefault(dependency, set()).add(package)

    revbumped: set[str] = set()
    for package in updated:
        for dependent in reverse.get(package, ()):
            if dependent in updated or dependent in excluded:
                continue
            if template_is_metapackage(repository.templates[dependent]):
                continue
            revbumped.add(dependent)

    changed = set(updated) | revbumped
    order = build_order(graph, changed)
    position = {package: index for index, package in enumerate(order)}

    rows: list[tuple[str, str, str, int]] = []
    for package in sorted(changed):
        kind = "version" if package in updated else "revision"
        rows.append((package, updated.get(package, ""), kind, position[package]))
    return rows, candidates


def apply_batch(root: Path, rows: list[tuple[str, str, str, int]]) -> None:
    """Apply the planned changes to the working tree."""
    for package, version, kind, _order in rows:
        if kind == "version":
            apply_version_bump(root, package, version)
        else:
            apply_revision_bump(root, package)


def write_plan(path: Path, rows: list[tuple[str, str, str, int]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    lines = [f"{package}\t{version}\t{kind}\t{order}" for package, version, kind, order in rows]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def read_plan(path: Path) -> list[tuple[str, str, str, int]]:
    """Read a plan written by write_plan."""
    rows: list[tuple[str, str, str, int]] = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) != 4:
            raise ValueError(f"malformed plan row {number} in {path}: {line!r}")
        package, version, kind, order = fields
        if not PACKAGE.fullmatch(package):
            raise ValueError(f"malformed package name in {path}: {package!r}")
        if kind not in ("version", "revision"):
            raise ValueError(f"unknown bump kind in {path}: {kind!r}")
        if kind == "version" and not VERSION.fullmatch(version):
            raise ValueError(f"malformed version in {path}: {version!r}")
        if not order.isdigit():
            raise ValueError(f"malformed build order in {path}: {order!r}")
        rows.append((package, version, kind, int(order)))
    return rows


def command_plan(args: argparse.Namespace, root: Path) -> int:
    rows, component = plan_batch(
        root,
        args.target,
        force=args.force,
        xbps_src=args.xbps_src,
    )
    write_plan(args.output, rows)
    write_component(args.output.with_suffix(".component"), component)
    if not rows:
        print(f"No updates detected among packages selected for {args.target}")
        return 0
    for package, version, kind, order in rows:
        detail = version if kind == "version" else "revision bump"
        print(f"{order + 1}. {package}: {detail}")
    return 0


def write_component(path: Path, component: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(component) + ("\n" if component else ""), encoding="utf-8")


def command_apply(args: argparse.Namespace, root: Path) -> int:
    rows = read_plan(args.plan)
    if not rows:
        print("The plan is empty; nothing to apply")
        return 0
    apply_batch(root, rows)
    for package, version, kind, order in rows:
        detail = version if kind == "version" else "revision bump"
        print(f"{order + 1}. {package}: {detail}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "apply"))
    parser.add_argument("target", nargs="?")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--plan", type=Path)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="checkout to work in; defaults to the repository this script lives in",
    )
    parser.add_argument(
        "--xbps-src",
        type=Path,
        default=Path(os.environ["XBPS_SRC"]) if os.environ.get("XBPS_SRC") else None,
        help="use this xbps-src to resolve evaluated build dependencies",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="bump the target even when it is in src/autobump-blacklist",
    )
    args = parser.parse_args()
    if args.xbps_src:
        args.xbps_src = args.xbps_src.resolve()
    root = args.repo_root.resolve()

    if args.command == "plan":
        if not args.target or not args.output:
            parser.error("plan requires a target and --output")
        return command_plan(args, root)

    if not args.plan:
        parser.error("apply requires --plan")
    return command_apply(args, root)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f"error: {error}")
