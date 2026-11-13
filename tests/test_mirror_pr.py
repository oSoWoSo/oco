#!/usr/bin/env python3
"""Behavior tests for cross-forge pull request mirroring."""

import importlib.util
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import URLError
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
            {"action": "assigned"},
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

    def test_closed_merged_github_source_marks_codeberg_mirror_manually_merged(self):
        self.api_responses = [{
            "number": 77,
            "head": {"ref": "mirror/github/pr-12"},
            "base": {"ref": "OCO"},
        }]
        self.event["action"] = "closed"
        self.event["pull_request"]["merged"] = True
        self.event["pull_request"]["merge_commit_sha"] = "b" * 40

        mirror.mirror_pr(self.event, "github", self.api, self.push)

        method, path, payload = self.calls[-1]
        self.assertEqual((method, path), ("POST", "/pulls/77/merge"))
        self.assertEqual(payload["do"], "manually-merged")
        self.assertEqual(payload["merge_commit_id"], "b" * 40)
        self.assertEqual(self.pushed, [])  # no branch push on close

    def test_closed_merged_github_mirror_of_codeberg_pr_marks_native_manually_merged(self):
        # The GitHub mirror of a Codeberg-native PR is merged on GitHub; the
        # native Codeberg PR must be marked merged too.
        self.event["action"] = "closed"
        self.event["pull_request"]["head"]["ref"] = "mirror/codeberg/pr-12"
        self.event["pull_request"]["head"]["sha"] = "a" * 40
        self.event["pull_request"]["merged"] = True
        self.event["pull_request"]["merge_commit_sha"] = "e" * 40

        responses = {"is_open": True, "merged": False}
        calls = []

        def api(method, path, payload=None):
            calls.append((method, path, payload))
            if method == "GET":
                if responses["is_open"]:
                    return {"number": 12, "state": "open", "merged": False}
                return {"number": 12, "state": "open", "merged": True}
            if method == "POST":
                responses["merged"] = True
                responses["is_open"] = False
            return {"number": 12}

        result = mirror.mirror_pr(self.event, "github", api, self.push)

        self.assertEqual(result["number"], 12)
        # GET the native PR, then POST manually-merged to the native PR.
        get_calls = [c for c in calls if c[0] == "GET" and c[1] == "/pulls/12"]
        self.assertEqual(len(get_calls), 1)
        merge_calls = [c for c in calls if c[0] == "POST" and c[1] == "/pulls/12/merge"]
        self.assertEqual(len(merge_calls), 1)
        self.assertEqual(merge_calls[0][2], {
            "do": "manually-merged",
            "merge_commit_id": "e" * 40,
        })
        self.assertEqual(self.pushed, [])

    def test_closed_unmerged_github_mirror_of_codeberg_pr_closes_native(self):
        self.event["action"] = "closed"
        self.event["pull_request"]["head"]["ref"] = "mirror/codeberg/pr-12"
        self.event["pull_request"]["head"]["sha"] = "a" * 40
        self.event["pull_request"]["merged"] = False

        calls = []

        def api(method, path, payload=None):
            calls.append((method, path, payload))
            if method == "GET":
                return {"number": 12, "state": "open", "merged": False}
            return {"number": 12}

        result = mirror.mirror_pr(self.event, "github", api, self.push)

        self.assertEqual(result["number"], 12)
        self.assertIn(("PATCH", "/pulls/12", {"state": "closed"}), calls)
        self.assertEqual(self.pushed, [])

    def test_closed_github_mirror_of_codeberg_pr_skips_already_closed_native(self):
        self.event["action"] = "closed"
        self.event["pull_request"]["head"]["ref"] = "mirror/codeberg/pr-12"
        self.event["pull_request"]["merged"] = True

        calls = []

        def api(method, path, payload=None):
            calls.append((method, path, payload))
            return {"number": 12, "state": "closed", "merged": True}

        mirror.mirror_pr(self.event, "github", api, self.push)

        # Only the GET probe; no write follows because the native PR is done.
        self.assertEqual(calls, [("GET", "/pulls/12", None)])

    def test_closed_github_mirror_of_codeberg_pr_ignores_non_codeberg_native(self):
        # A GitHub mirror of a GitHub PR (head mirror/github/pr-12) closed on
        # GitHub must not be treated as a native Codeberg close.
        self.event["action"] = "closed"
        self.event["pull_request"]["head"]["ref"] = "mirror/github/pr-12"
        self.event["pull_request"]["merged"] = True

        result = mirror.mirror_pr(self.event, "github", self.api, self.push)

        self.assertIsNone(result)
        self.assertEqual(self.calls, [])

    def test_closed_merged_codeberg_source_closes_github_mirror_with_comment(self):
        self.api_responses = [{
            "number": 77,
            "head": {"ref": "mirror/codeberg/pr-12"},
            "base": {"ref": "OCO"},
        }]
        self.event["pull_request"]["head"]["repo"]["clone_url"] = (
            "https://codeberg.org/contributor/oco.git"
        )
        self.event["pull_request"]["html_url"] = (
            "https://codeberg.org/oSoWoSo/oco/pulls/12"
        )
        self.event["action"] = "closed"
        self.event["pull_request"]["merged"] = True
        self.event["pull_request"]["merge_commit_sha"] = "c" * 40

        mirror.mirror_pr(self.event, "codeberg", self.api, self.push)

        close_calls = [c for c in self.calls if c[0] == "PATCH" and c[1] == "/pulls/77"]
        self.assertEqual(len(close_calls), 1)
        self.assertEqual(close_calls[0][2], {"state": "closed"})
        comment_calls = [c for c in self.calls if c[0] == "POST" and c[1] == "/issues/77/comments"]
        self.assertEqual(len(comment_calls), 1)
        self.assertIn("merged", comment_calls[0][2]["body"])

    def test_closed_merged_github_source_falls_back_to_close_when_manual_merge_fails(self):
        self.event["action"] = "closed"
        self.event["pull_request"]["merged"] = True
        self.event["pull_request"]["merge_commit_sha"] = "d" * 40

        def _api(method, path, payload=None):
            self.calls.append((method, path, payload))
            if method == "GET" and path.startswith("/pulls?"):
                return [{
                    "number": 77,
                    "head": {"ref": "mirror/github/pr-12"},
                    "base": {"ref": "OCO"},
                }]
            if method == "POST" and path == "/pulls/77/merge":
                raise RuntimeError("commit not yet in base branch")
            if method == "GET" and path == "/pulls/77":
                return {"number": 77, "merged": False, "state": "open"}
            return {"number": 77}

        with patch.object(mirror.time, "sleep"):
            mirror.mirror_pr(self.event, "github", _api, self.push)
        # After 3 failed merge attempts, fall back to PATCH close.
        closes = [c for c in self.calls if c[0] == "PATCH" and c[1] == "/pulls/77"]
        self.assertEqual(len(closes), 1)
        comments = [c for c in self.calls if c[0] == "POST" and c[1].endswith("/comments")]
        self.assertEqual(len(comments), 1)

    def test_closed_unmerged_source_closes_counterpart_on_both_forges(self):
        for source_forge, target_forge, head_prefix, clone_url, html_url in (
            ("github", "codeberg", "mirror/github/pr-12",
             "https://github.com/contributor/oco.git", "https://github.com/oSoWoSo/oco/pull/12"),
            ("codeberg", "github", "mirror/codeberg/pr-12",
             "https://codeberg.org/contributor/oco.git", "https://codeberg.org/oSoWoSo/oco/pulls/12"),
        ):
            with self.subTest(source=source_forge):
                calls = []
                responses = [{
                    "number": 77,
                    "head": {"ref": head_prefix},
                    "base": {"ref": "OCO"},
                }]

                def api(method, path, payload=None):
                    calls.append((method, path, payload))
                    if method == "GET":
                        return responses
                    return {"number": 77, "html_url": "https://target.example/pr/77"}

                event = {
                    "action": "closed",
                    "pull_request": {
                        "number": 12,
                        "html_url": html_url,
                        "head": {
                            "ref": "fix-package",
                            "sha": "a" * 40,
                            "repo": {"clone_url": clone_url},
                        },
                        "base": {"ref": "OCO"},
                        "merged": False,
                    },
                }
                mirror.mirror_pr(event, source_forge, api, self.push)
                self.assertEqual(calls[-1], ("PATCH", "/pulls/77", {"state": "closed"}))

    def test_closed_without_existing_mirror_is_noop(self):
        self.api_responses = []
        self.event["action"] = "closed"
        self.event["pull_request"]["merged"] = True

        result = mirror.mirror_pr(self.event, "github", self.api, self.push)

        self.assertIsNone(result)
        self.assertEqual(self.pushed, [])
        self.assertTrue(all(c[0] == "GET" for c in self.calls))

    def test_lookup_for_codeberg_target_is_scoped_to_mirror_branch_and_base(self):
        # Forgejo ignores the owner-prefixed head filter, so lookups against
        # Codeberg must pass the bare branch name or existing mirror PRs are
        # never found and creation duplicates them with HTTP 409.
        mirror.mirror_pr(self.event, "github", self.api, self.push)

        query = parse_qs(urlparse(self.calls[0][1]).query)
        self.assertEqual(query["head"], ["mirror/github/pr-12"])
        self.assertEqual(query["base"], ["OCO"])
        self.assertEqual(query["state"], ["all"])

    def test_lookup_for_github_target_uses_owner_qualified_branch(self):
        # GitHub matches PRs by "owner:branch"; the bare branch name returns
        # nothing there, so the Codeberg->GitHub direction keeps the prefix.
        self.event["pull_request"]["head"]["repo"]["clone_url"] = (
            "https://codeberg.org/contributor/oco.git"
        )
        self.event["pull_request"]["html_url"] = (
            "https://codeberg.org/oSoWoSo/oco/pulls/12"
        )

        mirror.mirror_pr(self.event, "codeberg", self.api, self.push)

        query = parse_qs(urlparse(self.calls[0][1]).query)
        self.assertEqual(query["head"], ["oSoWoSo:mirror/codeberg/pr-12"])
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

    def test_post_timeout_is_recoverable_when_mirror_was_actually_created(self):
        # A create request can time out after the server has already applied
        # it. The script must re-check instead of reporting a failure.
        mirror_state = {"exists": False}
        calls = []

        def api(method, path, payload=None):
            calls.append((method, path))
            if method == "GET":
                if mirror_state["exists"]:
                    return [{
                        "number": 77,
                        "head": {"ref": "mirror/github/pr-12"},
                        "base": {"ref": "OCO"},
                    }]
                return []
            mirror_state["exists"] = True
            raise mirror.ApiRequestTimeoutError(f"{method} {path} timed out")

        result = mirror.mirror_pr(self.event, "github", api, self.push)

        self.assertEqual(result["number"], 77)
        self.assertEqual(self.pushed[0][2], "mirror/github/pr-12")
        self.assertIn(("POST", "/pulls"), calls)
        self.assertGreaterEqual(len(calls), 3)  # GET lookup, POST, GET re-check

    def test_post_timeout_fails_through_when_mirror_is_really_missing(self):
        def api(method, path, payload=None):
            if method == "GET":
                return []
            raise mirror.ApiRequestTimeoutError(f"{method} {path} timed out")

        with self.assertRaises(mirror.ApiRequestTimeoutError):
            mirror.mirror_pr(self.event, "github", api, self.push)



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



class TimeoutDetectionTests(unittest.TestCase):
    def test_recognizes_urlerror_wrapping_socket_timeout(self):
        error = URLError(socket.timeout())
        self.assertTrue(mirror._is_timeout(error))

    def test_recognizes_plain_timeout_error(self):
        self.assertTrue(mirror._is_timeout(TimeoutError("read timed out")))

    def test_rejects_non_timeout_errors(self):
        for error in (
            ValueError("bad request"),
            OSError("connection reset by peer"),
            URLError("no host given"),
            URLError(OSError("name resolution failed")),
        ):
            with self.subTest(error=error):
                self.assertFalse(mirror._is_timeout(error))


if __name__ == "__main__":
    unittest.main()
