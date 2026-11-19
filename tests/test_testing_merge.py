import unittest
from unittest import mock
import sys
from pathlib import Path
import importlib.util

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("testing_merge", ROOT / "tools/autobump/testing-merge.py")
tm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tm)

ARGS = ["--run-id", "1", "--head-sha", "a" * 40, "--head-repo", "oSoWoSo/oco"]
T_PULL = {
    "number": 9,
    "title": "foo 1.2.3",
    "state": "open",
    "base": {"ref": "testing"},
    "head": {"ref": "T-autobump/foo", "sha": "a" * 40, "repo": {"full_name": "oSoWoSo/oco"}},
    "user": {"login": "oSoWoSo-bot"},
}


class TestingMergeTests(unittest.TestCase):
    HEAD = "a" * 40

    def setUp(self):
        self.calls = []
        self.get_responses = []

        def api(method, path, token, payload=None):
            self.calls.append((method, path, token, payload))
            if method == "GET":
                return self.get_responses.pop(0) if self.get_responses else None
            return {"merged": True, "sha": "s" * 40}

        self.api = api
        patcher = mock.patch.object(tm, "api_request", side_effect=api)
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_main(self, replace=None):
        argv = list(ARGS)
        if replace:
            for i in range(len(argv) - 1):
                if argv[i] in replace:
                    argv[i + 1] = replace[argv[i]]
        with mock.patch.object(sys, "argv", ["testing-merge"] + argv), \
                mock.patch.dict("os.environ", {"GH_TOKEN": "token"}):
            return tm.main()

    def test_skips_fork_prs(self):
        self.assertEqual(self.run_main(replace={"--head-repo": "fork/oco"}), 0)
        self.assertEqual(self.calls, [])

    def test_no_open_pr_returns_zero(self):
        self.get_responses = [[]]
        self.assertEqual(self.run_main(), 0)
        self.assertEqual(self.calls, [("GET", "/pulls?state=open&base=testing&per_page=100", "token", None)])

    def test_head_changed_since_build_skips_merge(self):
        current = dict(T_PULL)
        current["head"] = dict(current["head"], sha="b" * 40)
        self.get_responses = [
            [dict(T_PULL)],
            current,
        ]
        self.assertEqual(self.run_main(), 0)
        self.assertFalse(any(m == "PUT" for m, _, _, _ in self.calls))

    def test_base_changed_skips_merge(self):
        current = dict(T_PULL)
        current["base"] = {"ref": "OCO"}
        self.get_responses = [
            [dict(T_PULL)],
            current,
        ]
        self.assertEqual(self.run_main(), 0)
        self.assertFalse(any(m == "PUT" for m, _, _, _ in self.calls))

    def test_non_t_autobump_head_left_for_review(self):
        current = dict(T_PULL)
        current["head"] = dict(current["head"], ref="feature/foo")
        self.get_responses = [
            [dict(T_PULL)],
            current,
        ]
        self.assertEqual(self.run_main(), 0)
        self.assertFalse(any(m == "PUT" for m, _, _, _ in self.calls))

    def test_untrusted_author_left_for_review(self):
        current = dict(T_PULL)
        current["user"] = {"login": "some-contributor"}
        self.get_responses = [
            [dict(T_PULL)],
            current,
        ]
        self.assertEqual(self.run_main(), 0)
        self.assertFalse(any(m == "PUT" for m, _, _, _ in self.calls))

    def test_merges_matching_passed_pr_with_rebase(self):
        self.get_responses = [
            [dict(T_PULL)],
            dict(T_PULL),
        ]
        self.assertEqual(self.run_main(), 0)
        method, path, _tok, payload = self.calls[-1]
        self.assertEqual((method, path), ("PUT", "/pulls/9/merge"))
        self.assertEqual(payload["merge_method"], "rebase")
        self.assertEqual(payload["sha"], self.HEAD)


if __name__ == "__main__":
    unittest.main()