#!/usr/bin/env python3
"""Build workflows must not report success when required builds never ran."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BuildGateTests(unittest.TestCase):
    def status(self, **overrides):
        env = dict(os.environ, EVENT_NAME="push", CURRENT_BRANCH="OCO",
                   DETECT_RESULT="success", SYNC_RESULT="skipped",
                   LINT_RESULT="success", BUILD_RESULT="success",
                   PACKAGES="fixture", REMOVED="", SKIP_PUSH_PR="false",
                   HEAD_REF="", BASE_REF="")
        env.update(overrides)
        return subprocess.run(["bash", str(ROOT / ".github/scripts/build-gate.sh")],
                              env=env, text=True, capture_output=True)

    def test_successful_build(self):
        self.assertEqual(self.status().returncode, 0)

    def test_unsuccessful_or_missing_build_is_red(self):
        for event in ("push", "workflow_dispatch", "repository_dispatch", "pull_request"):
            for result in ("skipped", "failure", "cancelled", ""):
                with self.subTest(event=event, result=result):
                    self.assertNotEqual(self.status(EVENT_NAME=event, BUILD_RESULT=result).returncode, 0)

    def test_detection_sync_and_lint_must_succeed(self):
        for field in ("DETECT_RESULT", "LINT_RESULT"):
            for result in ("skipped", "failure", "cancelled"):
                self.assertNotEqual(self.status(**{field: result}).returncode, 0)
        self.assertNotEqual(self.status(SYNC_RESULT="failure").returncode, 0)

    def test_empty_push_and_dispatch_fail(self):
        for event in ("push", "workflow_dispatch", "repository_dispatch"):
            self.assertNotEqual(self.status(EVENT_NAME=event, PACKAGES="", BUILD_RESULT="skipped").returncode, 0)

    def test_metadata_only_pr_is_allowed(self):
        self.assertEqual(self.status(EVENT_NAME="pull_request", PACKAGES="", LINT_RESULT="skipped",
                                     BUILD_RESULT="skipped").returncode, 0)

    def test_removals_require_non_pr_job(self):
        self.assertEqual(self.status(PACKAGES="", REMOVED="old", LINT_RESULT="skipped").returncode, 0)
        self.assertNotEqual(self.status(PACKAGES="", REMOVED="old", BUILD_RESULT="skipped").returncode, 0)

    def test_only_feature_push_can_delegate_to_pr(self):
        args = dict(PACKAGES="", LINT_RESULT="skipped", BUILD_RESULT="skipped", SKIP_PUSH_PR="true")
        self.assertEqual(self.status(CURRENT_BRANCH="feature", **args).returncode, 0)
        self.assertNotEqual(self.status(**args).returncode, 0)
        self.assertNotEqual(self.status(EVENT_NAME="workflow_dispatch", CURRENT_BRANCH="feature", **args).returncode, 0)

    def test_workflow_checks_one_shared_build_path(self):
        workflow = (ROOT / ".github/workflows/build.yml").read_text()
        status = workflow.split("  build-gate:\n", 1)[1].split("  publish-request:\n", 1)[0]
        self.assertIn("if: always()", status)
        self.assertIn("needs: [detect, sync-testing, lint, build]", status)
        self.assertIn("BUILD_RESULT: ${{ needs.build.result }}", status)
        self.assertNotIn("test-pr:", workflow)
        self.assertNotIn("build-status:", workflow)
        self.assertEqual(workflow.count("run: bash .github/scripts/build-gate.sh"), 1)
        self.assertEqual(workflow.count("      - name: Build packages\n"), 1)
        condition = workflow.split("\n  build:\n", 1)[1].split("    runs-on:", 1)[0]
        self.assertIn("always()", condition)
        self.assertIn("needs.sync-testing.result == 'success'", condition)
        self.assertIn("github.event_name != 'pull_request' && needs.detect.outputs.removed != ''", condition)
        self.assertNotIn("skip_autobump", condition)
        self.assertNotIn("publish_from_pr", condition)

    def test_publication_requires_verified_build_and_lint(self):
        workflow = (ROOT / ".github/workflows/build.yml").read_text()
        request = workflow.split("  publish-request:\n", 1)[1].split("    runs-on:", 1)[0]
        self.assertIn("needs: [detect, build, build-gate]", request)
        self.assertIn("needs.build-gate.result == 'success'", request)
        self.assertIn("needs.detect.outputs.publish_from_pr != 'true'", request)
        self.assertIn("github.event_name != 'pull_request'", request)

    def test_publication_chain_overrides_skipped_ancestor_without_ignoring_failures(self):
        # A successful manual/push build still has a skipped sync-testing
        # ancestor. Every downstream publication job needs a status function,
        # not just result comparisons (which retain implicit success()).
        workflow = (ROOT / ".github/workflows/build.yml").read_text()
        expected = {
            "publish-request": ("detect", "build", "build-gate"),
            "publish": ("detect", "publish-request"),
            "close-update-issues": ("detect", "publish"),
        }
        for job, dependencies in expected.items():
            with self.subTest(job=job):
                block = workflow.split(f"\n  {job}:\n", 1)[1]
                condition = block.split("    if:", 1)[1].split("    runs-on:", 1)[0].split("    uses:", 1)[0]
                self.assertIn("!cancelled()", condition)
                for dependency in dependencies:
                    self.assertIn(f"needs.{dependency}.result == 'success'", condition)
        closer = workflow.split("\n  close-update-issues:\n", 1)[1]
        self.assertIn("needs.detect.outputs.publish_target == 'production'", closer)

    def test_shared_gate_always_runs_and_release_plan_stays_pr_only(self):
        workflow = (ROOT / ".github/workflows/build.yml").read_text()
        gate = workflow.split("\n  build-gate:\n", 1)[1].split("\n  publish-request:\n", 1)[0]
        header = gate.split("    runs-on:", 1)[0]
        self.assertIn("if: always()", header)
        self.assertIn("name: 🏗️ build gate", header)
        self.assertNotIn("github.event_name == 'pull_request'", header)
        for name in ("Write autobump release plan", "Upload autobump release plan"):
            condition = gate.split(f"      - name: {name}\n", 1)[1].split("        env:", 1)[0].split("        uses:", 1)[0]
            self.assertIn("github.event.pull_request.head.ref, 'autobump/'", condition)
            self.assertIn("github.event.pull_request.base.ref == 'OCO'", condition)
            self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", condition)

    def test_autobump_prs_cannot_use_the_metadata_only_exemption_or_remove_packages(self):
        for base, head in (("OCO", "autobump/fixture"), ("testing", "T-autobump/fixture")):
            with self.subTest(base=base):
                args = dict(EVENT_NAME="pull_request", BASE_REF=base, HEAD_REF=head)
                self.assertEqual(self.status(**args).returncode, 0)
                self.assertNotEqual(self.status(PACKAGES="", **args).returncode, 0)
                self.assertNotEqual(self.status(REMOVED="old", **args).returncode, 0)
                self.assertNotEqual(self.status(BUILD_RESULT="skipped", **args).returncode, 0)
                self.assertNotEqual(self.status(LINT_RESULT="failure", **args).returncode, 0)

    @unittest.skipUnless(shutil.which("jq"), "jq required by detector")
    def test_autobump_marker_only_delegates_publication(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            (repo / "lib").mkdir()
            shutil.copy(ROOT / "lib/pkg-helpers.sh", repo / "lib/pkg-helpers.sh")
            tpl = repo / "srcpkgs/fixture/template"
            tpl.parent.mkdir(parents=True)
            tpl.write_text("pkgname=fixture\nversion=1\nrevision=1\n")
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=repo, text=True).strip()
            git("init", "-q")
            git("add", ".")
            git("-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm", "initial")
            before = git("rev-parse", "HEAD")
            tpl.write_text(tpl.read_text().replace("version=1", "version=2"))
            git("add", ".")
            git("-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-qm",
                "fixture 2\n\nOCO-Autobump-Run: 123")
            after = git("rev-parse", "HEAD")
            bin_dir = repo / "bin"
            bin_dir.mkdir()
            pr = [{"number": 42, "merged_at": "2026-01-01", "base": {"ref": "OCO"},
                   "head": {"ref": "autobump/fixture", "repo": {"full_name": "example/oco"}},
                   "user": {"login": "oSoWoSo-bot"}}]
            gh = bin_dir / "gh"
            gh.write_text("#!/bin/sh\nprintf '%s\\n' '" + json.dumps(pr) + "'\n")
            gh.chmod(0o755)
            env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}",
                       INPUT_ALL="", INPUT_TEMPLATE="", INPUT_TEMPLATES="", INPUT_RUNNER="auto",
                       INPUT_PUBLISH_TARGET="production", EVENT_NAME="push", CURRENT_BRANCH="OCO",
                       PUSH_BEFORE=before, PUSH_AFTER=after, GITHUB_REF="refs/heads/OCO",
                       GITHUB_REF_NAME="OCO", GITHUB_REPOSITORY="example/oco",
                       GITHUB_SERVER_URL="https://github.com", GITHUB_OUTPUT=str(repo / "output"),
                       GITHUB_STEP_SUMMARY=str(repo / "summary"))
            result = subprocess.run(["bash", str(ROOT / ".github/scripts/build-detect.sh")],
                                    cwd=repo, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            outputs = dict(line.split("=", 1) for line in (repo / "output").read_text().splitlines())
            self.assertEqual(outputs["packages"], "fixture")
            self.assertEqual(outputs["publish_from_pr"], "true")
            self.assertEqual(outputs["skip_push_pr"], "false")
            self.assertTrue(json.loads(outputs["matrix"])["config"])
            summary = (repo / "summary").read_text()
            self.assertIn("Skipped publish jobs in this run are expected", summary)
            self.assertIn("/actions/workflows/autobump-release.yml", summary)
            self.assertIn("/actions/runs/123", summary)


if __name__ == "__main__":
    unittest.main()
