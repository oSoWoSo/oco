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

    def _build_dependencies(self, package: str, template: Path) -> set[str]:
        """Resolve dependencies with XBPS when available, otherwise parse literals."""
        if self.xbps_src is None:
            return template_dependencies(template)
        result = subprocess.run(
            [str(self.xbps_src), "show-build-deps", package],
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

    def dependencies(self) -> dict[str, set[str]]:
        """Return build dependency edges between real packages.

        In CI, `xbps-src show-build-deps` evaluates template/build-style
        dependency logic without building. The literal parser remains for
        isolated tests and local planning without an XBPS checkout.
        """
        edges: dict[str, set[str]] = {}
        for name, template in self.templates.items():
            resolved: set[str] = set()
            for dependency in self._build_dependencies(name, template):
                target = self.resolve(dependency) or dependency
                if target in self.templates and target != name:
                    resolved.add(target)
            edges[name] = resolved
        return edges

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


def build_order(graph: dict[str, set[str]], packages: set[str]) -> list[str]:
    """Order the packages so every dependency precedes its dependents.

    This mirrors the order `xbps-src sort-dependencies` produces for the
    build: dependencies first. The CI build still resolves the order with
    xbps-src itself, this only makes the commit sequence and the pull
    request body readable and deterministic.
    """
    ordered: list[str] = []
    visited: set[str] = set()

    def visit(name: str, stack: tuple[str, ...]) -> None:
        if name in visited:
            return
        if name in stack:
            # A dependency cycle is not ours to resolve; break it and keep
            # the deterministic order of the remaining packages.
            return
        for dependency in sorted(graph.get(name, ()) & packages):
            visit(dependency, stack + (name,))
        visited.add(name)
        ordered.append(name)

    for name in sorted(packages):
        visit(name, ())
    return ordered


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
    """Plan pack updates and revision bumps for direct build-dependent consumers.

    For a configured pack, upstream detection is limited to its members;
    outside-pack packages are included only when they need a rebuild.
    Unpacked packages retain dependency-component batching.
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

    graph = repository.dependencies()
    reachable = repository.pack_members(target) or component(graph, target)
    candidates = sorted(reachable - excluded)
    updated = detect_updates(root, candidates)
    if not updated:
        return [], candidates

    # Only direct build-dependent consumers need a revision bump for this
    # package change; unrelated members of the dependency component do not.
    reverse: dict[str, set[str]] = {}
    for package, dependencies in graph.items():
        for dependency in dependencies:
            reverse.setdefault(dependency, set()).add(package)

    revbumped: set[str] = set()
    for package in updated:
        for dependent in reverse.get(package, ()):
            if dependent in updated:
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
