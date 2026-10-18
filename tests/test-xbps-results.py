#!/usr/bin/env python3
"""Focused tests for XBPS output result collection and its consumers."""

import hashlib
import importlib.util
import plistlib
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


collector = load("collect_xbps_results", "src/collect-xbps-results.py")
feed = load("gen_feed", "src/gen-feed.py")
closer = load("close_update_issues", "src/close-update-issues.py")
release = load("autobump_release", "src/autobump-release.py")


def make_xbps(path: Path, *, pkgname: str, sourcepkg: str, version: str,
              arch: str = "x86_64", pkgver: str | None = None) -> None:
    version_revision = f"{version}_1"
    properties = {
        "pkgname": pkgname,
        "pkgver": pkgver or f"{pkgname}-{version_revision}",
        "version": version_revision,
        "architecture": arch,
        "sourcepkg": sourcepkg,
    }
    with tempfile.TemporaryDirectory() as tmp:
        temp = Path(tmp)
        (temp / "props.plist").write_bytes(plistlib.dumps(properties, fmt=plistlib.FMT_XML))
        subprocess.run(
            ["tar", "--zstd", "-cf", str(path), "-C", tmp, "./props.plist"],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )


def test_binary_collection() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        results = root / "results.tsv"
        source_rows = "target\t1.2.3\tok\ndependency\t2.0\tok\nfailed-dep\t3.0\tfail\n"
        results.write_text(source_rows)
        binpkgs = root / "binpkgs"
        (binpkgs / "nested").mkdir(parents=True)
        make_xbps(binpkgs / "target-1.2.3_1.x86_64.xbps",
                  pkgname="target", sourcepkg="target", version="1.2.3")
        make_xbps(binpkgs / "nested/target-devel-1.2.3_1.x86_64.xbps",
                  pkgname="target-devel", sourcepkg="target", version="1.2.3")
        make_xbps(binpkgs / "nested/dependency-docs-2.0_1.x86_64.xbps",
                  pkgname="dependency-docs", sourcepkg="dependency", version="2.0")
        make_xbps(binpkgs / "unrelated-9.0_1.x86_64.xbps",
                  pkgname="unrelated", sourcepkg="unrelated", version="9.0")

        assert collector.collect(results, binpkgs, "x86_64") == 2
        lines = results.read_text().splitlines()
        assert lines[:3] == source_rows.splitlines()
        assert "target-devel\t1.2.3\tok\ttarget" in lines
        assert "dependency-docs\t2.0\tok\tdependency" in lines
        assert not any(line.startswith("target\t1.2.3\tok\t") for line in lines)
        assert not any(line.startswith("unrelated\t") for line in lines)

        bad_results = root / "bad-results.tsv"
        bad_results.write_text("target\t1.2.3\tok\n")
        malformed = binpkgs / "target-bad-1.2.3_1.x86_64.xbps"
        malformed.write_bytes(b"not an xbps archive")
        try:
            collector.collect(bad_results, binpkgs, "x86_64")
        except ValueError:
            pass
        else:
            raise AssertionError("malformed candidate XBPS metadata was accepted")


def make_release_artifacts(root: Path, rows: list[str]):
    artifacts = root / "artifacts"
    (artifacts / "autobump-release-plan").mkdir(parents=True)
    folder = artifacts / "autobump-bin-x86_64-x86_64"
    packages = folder / "packages"
    packages.mkdir(parents=True)
    filename = "target-1.2.3_1.x86_64.xbps"
    binary = packages / filename
    binary.write_bytes(b"synthetic xbps payload")
    result = folder / "results.tsv"
    result.write_text("\n".join(rows) + "\n")
    import json
    (folder / "manifest.json").write_text(json.dumps({
        "arch": "x86_64", "host": "x86_64",
        "files": [{"name": filename, "sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}],
        "results_sha256": hashlib.sha256(result.read_bytes()).hexdigest(),
    }))
    return artifacts, {"matrix": {"config": [{"arch": "x86_64", "host": "x86_64"}]}}


def test_consumers_and_release_validation() -> None:
    rows = [
        "target\t1.2.3\tok",
        "dependency\t2.0\tfail",
        "target-devel\t1.2.3\tok\ttarget",
    ]
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        results_dir = root / "results/build-results-x86_64"
        results_dir.mkdir(parents=True)
        (results_dir / "results.tsv").write_text(
            "legacy\t1.0\tok\n" + "\n".join(rows) + "\n"
        )
        ok, failed = closer.collect_results(str(root / "results"))
        assert ok["legacy"] == {"1.0"}
        assert ok["target-devel"] == {"1.2.3"}
        assert failed["dependency"] == {"2.0"}

        source_dir = root / "srcpkgs"
        (source_dir / "target").mkdir(parents=True)
        (source_dir / "target/template").write_text(
            'homepage="https://source.example/target"\nshort_desc="Source description"\n'
        )
        feed_rows = root / "feed-results/build-results-x86_64"
        feed_rows.mkdir(parents=True)
        (feed_rows / "results.tsv").write_text("target-devel\t1.2.3\tok\ttarget\n")
        feed_path = root / "feed.xml"
        feed.update_feed(str(feed_path), str(root / "feed-results"), "42",
                         "2026-10-14", str(source_dir))
        xml = feed_path.read_text()
        assert "target-devel 1.2.3" in xml
        assert "https://source.example/target" in xml
        assert "srcpkgs/target/template" in xml
        assert "Source description" in xml

        artifacts, plan = make_release_artifacts(root, rows)
        release.stage(artifacts, root / "staging", plan, "target", "1.2.3")
        staged = (root / "staging/results/build-results-x86_64/results.tsv").read_text().splitlines()
        assert sorted(staged) == sorted(rows)

        def rejects(invalid_rows):
            with tempfile.TemporaryDirectory() as invalid_tmp:
                invalid_root = Path(invalid_tmp)
                bad_artifacts, bad_plan = make_release_artifacts(invalid_root, invalid_rows)
                try:
                    release.stage(bad_artifacts, invalid_root / "staging", bad_plan,
                                  "target", "1.2.3")
                except ValueError:
                    return
            raise AssertionError(f"invalid release rows accepted: {invalid_rows!r}")

        rejects(["target\t1.2.4\tok"])
        rejects(["target\t1.2.3\tfail"])
        rejects(["dependency\t2.0\tok"])
        rejects(["target\t1.2.3\tok", "orphan\t1.2.3\tok\tmissing-source"])


def test_autobump_merge_commit_message() -> None:
    title, body = release.merge_commit_message({
        "package": "opencode2",
        "version": "2.0.32",
        "run_id": 38993480199,
        "head_sha": "a" * 40,
    })
    assert title == "opencode2 2.0.32"
    assert body == (
        "OCO-Autobump-Run: 38993480199\n"
        f"OCO-Autobump-Head: {'a' * 40}"
    )


def test_release_pr_author_validation() -> None:
    plan = {
        "pr_number": 42,
        "head_ref": "autobump/target-1.2.3",
        "head_sha": "a" * 40,
        "base_sha": "b" * 40,
        "packages": "target",
    }
    files = [{"filename": "srcpkgs/target/template", "status": "modified"}]

    def pr_for(author):
        return {
            "number": 42,
            "base": {"ref": "OCO", "sha": "b" * 40},
            "head": {
                "repo": {"full_name": "owner/repo"},
                "ref": "autobump/target-1.2.3",
                "sha": "a" * 40,
            },
            "user": {"login": author},
            "merged": False,
            "state": "open",
            "changed_files": 1,
        }

    for author in ("oSoWoSo-bot", "zen0bit", "zenobit"):
        assert release.check_pr(pr_for(author), files, repo="owner/repo",
                                plan=plan, allow_merged=False) == "target"

    try:
        release.check_pr(pr_for("untrusted-user"), files, repo="owner/repo",
                         plan=plan, allow_merged=False)
    except ValueError:
        pass
    else:
        raise AssertionError("PR from an untrusted author was accepted")


if __name__ == "__main__":
    test_binary_collection()
    test_consumers_and_release_validation()
    test_autobump_merge_commit_message()
    test_release_pr_author_validation()
    print("XBPS result tests passed")
