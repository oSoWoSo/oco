#!/usr/bin/env python3
"""Behavior tests for cross-forge pull request mirroring."""

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "mirror_pr", ROOT / ".github/scripts/ci/mirror-pr.py"
)
mirror = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mirror)


class MirrorPullRequestTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.api_responses = []

        def api(method, path, payload=None):
            self.calls.append((method, path, payload))
            if method == "GET":
                return self.api_responses
            return {"number": 77, "html_url": "https://target.example/pr/77"}

        self.api = api
        self.pushed = []

        def push(source_url, commit, branch):
            self.pushed.append((source_url, commit, branch))

        self.push = push
        self.event = {
            "action": "opened",
            "pull_request": {
                "number": 12,
                "title": "Fix package",
                "body": "Description",
                "html_url": "https://github.com/contributor/oco/pull/12",
                "head": {
                    "ref": "fix-package",
                    "sha": "a" * 40,
                    "repo": {"clone_url": "https://github.com/contributor/oco.git"},
                },
                "base": {"ref": "OCO"},
            },
        }

    def test_opened_pr_pushes_source_and_creates_one_mirror(self):
        result = mirror.mirror_pr(self.event, "github", self.api, self.push)

        self.assertEqual(result["number"], 77)
        self.assertEqual(
            self.pushed,
            [("https://github.com/contributor/oco.git", "a" * 40, "mirror/github/pr-12")],
        )
        method, path, payload = self.calls[-1]
        self.assertEqual((method, path), ("POST", "/pulls"))
        self.assertEqual(payload["head"], "mirror/github/pr-12")
        self.assertEqual(payload["base"], "OCO")
        self.assertEqual(payload["title"], "Fix package")
        self.assertIn("Mirrored from https://github.com/contributor/oco/pull/12", payload["body"])

    def test_retry_updates_existing_mirror_instead_of_creating_duplicate(self):
        self.api_responses = [{
            "number": 77,
            "head": {"ref": "mirror/github/pr-12"},
            "base": {"ref": "OCO"},
        }]
        self.event["action"] = "synchronize"
        self.event["pull_request"]["title"] = "Updated title"

        result = mirror.mirror_pr(self.event, "github", self.api, self.push)

        self.assertEqual(result["number"], 77)
        method, path, payload = self.calls[-1]
        self.assertEqual((method, path), ("PATCH", "/pulls/77"))
        self.assertEqual(payload["title"], "Updated title")
        self.assertNotIn("head", payload)

    def test_non_oco_and_unsupported_events_have_no_effects(self):
        for change in (
            {"action": "closed"},
            {"pull_request": {"base": {"ref": "other"}}},
            {"pull_request": {"head": {"ref": "mirror/codeberg/pr-3"}}},
        ):
            event = {
                **self.event,
                "pull_request": {
                    **self.event["pull_request"],
                    "head": dict(self.event["pull_request"]["head"]),
                    "base": dict(self.event["pull_request"]["base"]),
                },
            }
            event.update({key: value for key, value in change.items() if key == "action"})
            if "pull_request" in change:
                event["pull_request"].update(change["pull_request"])
            with self.subTest(change=change):
                self.assertIsNone(mirror.mirror_pr(event, "github", self.api, self.push))
        self.assertEqual(self.calls, [])
        self.assertEqual(self.pushed, [])

    def test_reopen_explicitly_reopens_existing_counterpart(self):
        self.api_responses = [{
            "number": 77,
            "head": {"ref": "mirror/codeberg/pr-12"},
            "base": {"ref": "OCO"},
        }]
        self.event["action"] = "reopened"
        self.event["pull_request"]["head"]["ref"] = "fix-package"
        mirror.mirror_pr(self.event, "codeberg", self.api, self.push)

        method, path, payload = self.calls[-1]
        self.assertEqual((method, path), ("PATCH", "/pulls/77"))
        self.assertEqual(payload["state"], "open")
        self.assertEqual(self.pushed[0][2], "mirror/codeberg/pr-12")

    def test_lookup_is_scoped_to_mirror_branch_and_base(self):
        mirror.mirror_pr(self.event, "github", self.api, self.push)

        query = parse_qs(urlparse(self.calls[0][1]).query)
        self.assertEqual(query["head"], ["oSoWoSo:mirror/github/pr-12"])
        self.assertEqual(query["base"], ["OCO"])
        self.assertEqual(query["state"], ["all"])

    def test_codeberg_pr_creates_github_head_using_owner_qualified_branch(self):
        self.event["pull_request"]["head"]["repo"]["clone_url"] = (
            "https://codeberg.org/contributor/oco.git"
        )
        self.event["pull_request"]["html_url"] = (
            "https://codeberg.org/oSoWoSo/oco/pulls/12"
        )

        mirror.mirror_pr(self.event, "codeberg", self.api, self.push)

        method, path, payload = self.calls[-1]
        self.assertEqual((method, path), ("POST", "/pulls"))
        self.assertEqual(payload["head"], "oSoWoSo:mirror/codeberg/pr-12")



class SourceValidationTests(unittest.TestCase):
    def test_only_expected_https_forge_hosts_are_fetchable(self):
        for source, forge in (
            ("https://github.com/user/oco.git", "github"),
            ("https://codeberg.org/user/oco.git", "codeberg"),
        ):
            with self.subTest(source=source):
                mirror.validate_source_url(source, forge)

        for source, forge in (
            ("http://github.com/user/oco.git", "github"),
            ("https://evil.example/user/oco.git", "github"),
            ("https://token@github.com/user/oco.git", "github"),
        ):
            with self.subTest(source=source):
                with self.assertRaises(ValueError):
                    mirror.validate_source_url(source, forge)


class PushBranchTests(unittest.TestCase):
    def test_pushes_the_complete_source_history_to_namespaced_branch(self):
        with tempfile.TemporaryDirectory(prefix="oco-mirror-git-test-") as directory:
            temp = Path(directory)
            source_work = temp / "source-work"
            source_bare = temp / "source.git"
            target_bare = temp / "target.git"
            config = temp / "gitconfig"

            subprocess.run(["git", "init", "-q", str(source_work)], check=True)
            subprocess.run(
                ["git", "-C", str(source_work), "config", "user.name", "Mirror test"],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(source_work), "config", "user.email", "mirror@example.invalid"],
                check=True,
            )
            payload = source_work / "payload.txt"
            payload.write_text("first commit\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(source_work), "add", "payload.txt"], check=True)
            subprocess.run(["git", "-C", str(source_work), "commit", "-qm", "first"], check=True)
            payload.write_text("second commit\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(source_work), "commit", "-qam", "second"], check=True)
            commit = subprocess.check_output(
                ["git", "-C", str(source_work), "rev-parse", "HEAD"], text=True
            ).strip()
            subprocess.run(
                ["git", "clone", "-q", "--bare", str(source_work), str(source_bare)],
                check=True,
            )
            subprocess.run(["git", "init", "-q", "--bare", str(target_bare)], check=True)

            config.write_text(
                f'[url "file://{source_bare}"]\n'
                "    insteadOf = https://codeberg.org/contributor/oco.git\n"
                f'[url "file://{target_bare}"]\n'
                "    insteadOf = https://github.com/oSoWoSo/oco.git\n",
                encoding="utf-8",
            )

            with patch.dict(os.environ, {"GIT_CONFIG_GLOBAL": str(config)}):
                mirror.push_source_branch(
                    "https://codeberg.org/contributor/oco.git",
                    commit,
                    "https://github.com/oSoWoSo/oco.git",
                    "mirror/codeberg/pr-12",
                    "test-token",
                    "x-access-token",
                    "codeberg",
                )

            branch = "refs/heads/mirror/codeberg/pr-12"
            self.assertEqual(
                subprocess.check_output(
                    ["git", "--git-dir", str(target_bare), "rev-parse", branch], text=True
                ).strip(),
                commit,
            )
            self.assertEqual(
                subprocess.check_output(
                    ["git", "--git-dir", str(target_bare), "rev-list", "--count", branch],
                    text=True,
                ).strip(),
                "2",
            )



if __name__ == "__main__":
    unittest.main()
