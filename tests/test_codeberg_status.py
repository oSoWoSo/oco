#!/usr/bin/env python3
"""Behavior tests for the Codeberg commit-status reporter."""

import importlib.util
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "codeberg_status", ROOT / ".github/scripts/ci/codeberg-status.py"
)
status = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(status)


class CodebergStatusTests(unittest.TestCase):
    def test_posts_status_to_codeberg_api(self):
        captured = {}

        def fake_urlopen(request, timeout):
            captured["request"] = request
            captured["timeout"] = timeout
            return _FakeResponse({"url": "https://codeberg.org/api/v1/repos/oSoWoSo/oco/statuses/abc"})

        with patch.object(status, "urlopen", fake_urlopen):
            result = status.post_status(
                "cb-token",
                "a" * 40,
                "success",
                "GitHub Actions checks passed",
                "https://github.com/oSoWoSo/oco/actions/runs/1",
            )

        request = captured["request"]
        self.assertIsInstance(request, Request)
        self.assertEqual(request.method, "POST")
        self.assertEqual(request.full_url, f"{status.API_ROOT}/statuses/{'a' * 40}")
        self.assertEqual(request.headers["Authorization"], "token cb-token")
        lowered = {k.lower(): v for k, v in request.headers.items()}
        self.assertEqual(lowered["content-type"], "application/json")
        self.assertEqual(captured["timeout"], 30)
        body = json.loads(request.data.decode())
        self.assertEqual(
            body,
            {
                "state": "success",
                "context": "ci/github",
                "description": "GitHub Actions checks passed",
                "target_url": "https://github.com/oSoWoSo/oco/actions/runs/1",
            },
        )
        self.assertEqual(result["url"], f"{status.API_ROOT}/statuses/abc")

    def test_rejects_unknown_states_and_bad_shas(self):
        with self.assertRaises(ValueError):
            status.post_status("t", "a" * 40, "waffling", "", "")
        with self.assertRaises(ValueError):
            status.post_status("t", "short", "success", "", "")
        with self.assertRaises(ValueError):
            status.post_status("t", "z" * 40, "success", "", "")  # non-hex

    def test_http_errors_are_surfaced(self):
        def fake_urlopen(request, timeout):
            raise HTTPError(
                "https://codeberg.org/api/v1/repos/oSoWoSo/oco/statuses/" + "a" * 40,
                401,
                "Unauthorized",
                {},
                None,
            )

        with patch.object(status, "urlopen", fake_urlopen):
            with self.assertRaises(RuntimeError) as ctx:
                status.post_status("bad-token", "a" * 40, "failure", "", "")
        self.assertIn("401", str(ctx.exception))

    def test_404_commit_is_a_skip_not_a_failure(self):
        def fake_urlopen(request, timeout):
            raise HTTPError(
                "https://codeberg.org/api/v1/repos/oSoWoSo/oco/statuses/" + "a" * 40,
                404,
                "Not Found",
                {},
                None,
            )

        with patch.object(status, "urlopen", fake_urlopen):
            with self.assertRaises(status.CommitUnavailableError):
                status.post_status("t", "a" * 40, "success", "", "")
            with patch.dict(
                os.environ,
                {
                    "CODEBERG_TOKEN": "t",
                    "COMMIT_SHA": "b" * 40,
                    "STATUS_STATE": "success",
                },
            ):
                self.assertEqual(status.main(), 0)


class _FakeResponse:
    def __init__(self, payload):
        self._payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self):
        return json.dumps(self._payload).encode()


if __name__ == "__main__":
    unittest.main()