#!/usr/bin/env python3
"""Regression tests for the dependency-connected autobump batch planner."""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "autobump_batch", ROOT / ".github/scripts/autobump-batch.py"
)
batch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(batch)


def write_template(root: Path, name: str, body: str) -> Path:
    directory = root / "srcpkgs" / name
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "template").write_text(body, encoding="utf-8")
    return directory / "template"


class BatchPlanTests(unittest.TestCase):
    """The planner groups by dependency and bumps reverse dependencies."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        (self.tmp / "src").mkdir()
        (self.tmp / ".github" / "scripts").mkdir(parents=True)
        for script in ("autobump-batch.py", "bump-template.sh", "bump-revision.sh",
                       "detect-update.sh"):
            shutil.copy(ROOT / ".github" / "scripts" / script,
                        self.tmp / ".github" / "scripts" / script)

    def build_repo(self, templates: dict, blacklist: list[str] | None = None) -> None:
        for name, body in templates.items():
            write_template(self.tmp, name, body)
        (self.tmp / "src" / "autobump-blacklist").write_text(
            "\n".join(blacklist or []) + "\n", encoding="utf-8")

    def fake_detector(self, updates: dict) -> None:
        """Replace detect-update.sh with a script that reports fixed versions."""
        script = self.tmp / ".github" / "scripts" / "detect-update.sh"
        script.write_text(
            "#!/bin/sh\n"
            'pkg="$1"\n'
            'cd "$2" || exit 1\n'
            'new="${FAKE_UPDATES:-}"\n'
            'for pair in $new; do\n'
            '  name=${pair%%:*}\n'
            '  version=${pair#*:}\n'
            '  if [ "$name" = "$pkg" ]; then\n'
            '    old=$(sed -n \'s/^version=//p\' "srcpkgs/$pkg/template" | head -1)\n'
            '    echo "$pkg $old $version"\n'
            '    exit 0\n'
            '  fi\n'
            'done\n'
            'exit 0\n',
            encoding="utf-8",
        )
        os.environ["FAKE_UPDATES"] = " ".join(
            f"{name}:{version}" for name, version in updates.items()
        )
        self.addCleanup(os.environ.pop, "FAKE_UPDATES", None)

    def plan(self, target: str, **kwargs):
        kwargs.setdefault("force", False)
        return batch.plan_batch(self.tmp, target, **kwargs)

    def test_multi_line_dependencies_are_read(self):
        """A quoted dependency list may span several lines."""
        path = write_template(self.tmp, "shell", (
            "pkgname=shell\n"
            "version=1.0\n"
            "revision=1\n"
            "depends=\"\n"
            "\talpha\n"
            "\tbeta\n"
            "\tgamma>=1.2\"\n"
        ))
        self.assertEqual(batch.template_dependencies(path), {"alpha", "beta", "gamma"})

    def test_shell_expansions_are_not_dependency_edges(self):
        """An expanded list would connect packages that are not related."""
        path = write_template(self.tmp, "dynamic", (
            "pkgname=dynamic\n"
            "version=1.0\n"
            "revision=1\n"
            "depends=\"$(cat extra-deps) plain\"\n"
        ))
        self.assertEqual(batch.template_dependencies(path), {"plain"})

    def test_alias_dependency_resolves_to_the_real_package(self):
        """A -devel symlink points at the package that is actually bumped."""
        self.build_repo({
            "real": "pkgname=real\nversion=1.0\nrevision=1\n",
            "user": "pkgname=user\nversion=1.0\nrevision=1\n"
                    "depends=\"real-devel\"\n",
        })
        (self.tmp / "srcpkgs" / "real-devel").symlink_to("real")

        repository = batch.Repository(self.tmp)
        graph = repository.dependencies()
        self.assertEqual(graph["user"], {"real"})

    def test_batch_groups_connected_packages_and_omits_unrelated_ones(self):
        self.build_repo({
            "alpha": "pkgname=alpha\nversion=1.0\nrevision=1\n",
            "beta": "pkgname=beta\nversion=1.0\nrevision=1\ndepends=\"alpha\"\n",
            "gamma": "pkgname=gamma\nversion=1.0\nrevision=1\ndepends=\"beta\"\n",
            "lonely": "pkgname=lonely\nversion=1.0\nrevision=1\n",
        })
        self.fake_detector({"alpha": "1.1", "beta": "2.0", "lonely": "9.9"})

        rows, component = self.plan("alpha")
        kinds = {package: kind for package, _version, kind, _order in rows}

        # alpha and beta are connected to the target, gamma hangs off beta.
        # lonely is a component of its own and stays out of the batch.
        self.assertEqual(set(kinds), {"alpha", "beta", "gamma"})
        self.assertEqual(kinds["alpha"], "version")
        self.assertEqual(kinds["beta"], "version")
        self.assertEqual(kinds["gamma"], "revision")
        self.assertNotIn("lonely", kinds)
        self.assertNotIn("lonely", component)

    def test_reverse_dependency_gets_a_revision_bump(self):
        self.build_repo({
            "alpha": "pkgname=alpha\nversion=1.0\nrevision=1\n",
            "consumer": "pkgname=consumer\nversion=1.0\nrevision=4\ndepends=\"alpha\"\n",
        })
        self.fake_detector({"alpha": "1.1"})

        rows, _component = self.plan("alpha")
        kinds = {package: kind for package, _version, kind, _order in rows}
        self.assertEqual(kinds, {"alpha": "version", "consumer": "revision"})

    def test_package_with_an_update_is_not_revbumped_as_well(self):
        self.build_repo({
            "alpha": "pkgname=alpha\nversion=1.0\nrevision=1\n",
            "consumer": "pkgname=consumer\nversion=1.0\nrevision=4\ndepends=\"alpha\"\n",
        })
        self.fake_detector({"alpha": "1.1", "consumer": "3.0"})

        rows, _component = self.plan("alpha")
        kinds = {package: kind for package, _version, kind, _order in rows}
        self.assertEqual(kinds, {"alpha": "version", "consumer": "version"})

    def test_metapackage_dependent_is_not_revbumped(self):
        """A metapackage ships no binaries, so its revision stays put."""
        self.build_repo({
            "alpha": "pkgname=alpha\nversion=1.0\nrevision=1\n",
            "meta": "pkgname=meta\nversion=1.0\nrevision=1\nmetapackage=\"yes\"\n"
                    "depends=\"alpha\"\n",
        })
        self.fake_detector({"alpha": "1.1"})

        rows, _component = self.plan("alpha")
        kinds = {package: kind for package, _version, kind, _order in rows}
        self.assertEqual(kinds, {"alpha": "version"})

    def test_build_order_places_dependencies_first(self):
        self.build_repo({
            "alpha": "pkgname=alpha\nversion=1.0\nrevision=1\n",
            "beta": "pkgname=beta\nversion=1.0\nrevision=1\ndepends=\"alpha\"\n",
        })
        self.fake_detector({"alpha": "1.1", "beta": "2.0"})

        rows, _component = self.plan("alpha")
        order = {package: position for package, _v, _k, position in rows}
        self.assertLess(order["alpha"], order["beta"])

    def test_target_in_the_blacklist_is_refused(self):
        self.build_repo({
            "alpha": "pkgname=alpha\nversion=1.0\nrevision=1\n",
        }, ["alpha"])
        with self.assertRaises(ValueError) as exc:
            self.plan("alpha")
        self.assertIn("autobump-blacklist", str(exc.exception))

    def test_symlink_alias_target_is_refused_without_listing_it(self):
        """Aliases are excluded automatically; force still bumps the real one."""
        self.build_repo({
            "real": "pkgname=real\nversion=1.0\nrevision=1\n",
        })
        (self.tmp / "srcpkgs" / "real-devel").symlink_to("real")

        with self.assertRaises(ValueError) as exc:
            self.plan("real-devel")
        self.assertIn("symlink alias", str(exc.exception))

        rows, _component = self.plan("real", force=True)
        self.assertEqual(rows, [])

    def test_plan_is_empty_when_nothing_is_new(self):
        self.build_repo({
            "alpha": "pkgname=alpha\nversion=1.0\nrevision=1\n",
        })
        self.fake_detector({})

        rows, component = self.plan("alpha")
        self.assertEqual(rows, [])
        self.assertEqual(component, ["alpha"])


class BatchApplyTests(unittest.TestCase):
    """Applying the plan changes the templates the way the helpers do."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        (self.tmp / "src").mkdir()
        (self.tmp / ".github" / "scripts").mkdir(parents=True)
        for script in ("autobump-batch.py", "bump-template.sh", "bump-revision.sh"):
            shutil.copy(ROOT / ".github" / "scripts" / script,
                        self.tmp / ".github" / "scripts" / script)

    def test_revision_bump_leaves_version_and_checksum_alone(self):
        template = write_template(self.tmp, "consumer", (
            "pkgname=consumer\n"
            "version=1.0\n"
            "revision=4\n"
            "checksum=abc123\n"
        ))
        batch.apply_revision_bump(self.tmp, "consumer")
        text = template.read_text(encoding="utf-8")
        self.assertIn("version=1.0", text)
        self.assertIn("revision=5", text)
        self.assertIn("checksum=abc123", text)

    def test_revision_bump_keeps_a_trailing_comment(self):
        template = write_template(self.tmp, "consumer", (
            "pkgname=consumer\n"
            "version=1.0\n"
            "revision=2 # bumped by hand\n"
        ))
        batch.apply_revision_bump(self.tmp, "consumer")
        self.assertIn("revision=3 # bumped by hand", template.read_text(encoding="utf-8"))

    def test_plan_round_trip(self):
        write_template(self.tmp, "alpha",
                       "pkgname=alpha\nversion=1.0\nrevision=1\n")
        write_template(self.tmp, "consumer",
                       "pkgname=consumer\nversion=1.0\nrevision=1\ndepends=\"alpha\"\n")
        (self.tmp / "src" / "autobump-blacklist").write_text("# none\n", encoding="utf-8")

        rows = [("alpha", "1.1", "version", 0), ("consumer", "", "revision", 1)]
        plan_file = self.tmp / "plan.tsv"
        batch.write_plan(plan_file, rows)
        self.assertEqual(batch.read_plan(plan_file), rows)

    def test_read_plan_rejects_a_malformed_row(self):
        plan_file = self.tmp / "plan.tsv"
        plan_file.write_text("alpha\t1.1\tversion\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            batch.read_plan(plan_file)


class HelperTests(unittest.TestCase):
    """The shared helpers behave the way the planner assumes."""

    def test_bump_revision_reports_the_new_revision(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_template(root, "consumer",
                           "pkgname=consumer\nversion=1.0\nrevision=7\n")
            result = subprocess.run(
                ["bash", str(ROOT / ".github/scripts/bump-revision.sh"), "consumer", str(root)],
                check=False, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "consumer 8")
            self.assertIn("revision=8", (root / "srcpkgs/consumer/template").read_text())

    def test_bump_revision_refuses_a_missing_template(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(
                ["bash", str(ROOT / ".github/scripts/bump-revision.sh"), "ghost", tmp],
                check=False, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 2)

    def test_bump_template_accepts_a_repo_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_template(root, "demo", (
                "pkgname=demo\n"
                "version=1.0\n"
                "revision=1\n"
                'distfiles="https://example.com/demo-${version}.tar.gz"\n'
                "checksum=0000\n"
            ))
            # The download cannot happen offline, but the helper has to
            # accept the third argument and fail on the download, not on
            # the usage line.
            result = subprocess.run(
                ["bash", str(ROOT / ".github/scripts/bump-template.sh"),
                 "demo", "1.1", str(root)],
                check=False, capture_output=True, text=True,
            )
            self.assertNotIn("usage:", result.stderr)
            self.assertEqual(result.returncode, 2)

    def test_bump_template_updates_source_less_metapackage(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            template = write_template(root, "desktop", (
                "pkgname=desktop\n"
                "version=1.0\n"
                "revision=1\n"
                'metapackage="yes"\n'
                "skip_extraction=yes\n"
            ))
            result = subprocess.run(
                ["bash", str(ROOT / ".github/scripts/bump-template.sh"),
                 "desktop", "1.1", str(root)],
                check=False, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(result.stdout.strip().endswith("desktop 1.1"))
            self.assertIn("version=1.1", template.read_text(encoding="utf-8"))


if __name__ == "__main__":
    sys.exit(unittest.main())
