#!/usr/bin/env python3
"""Validate autobump build artifacts, merge the tested PR, and stage binaries.

This script MUST run only from the trusted OCO checkout in a workflow_run job.
Never execute code extracted from a PR artifact.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ARCHES = {"x86_64", "x86_64-musl", "aarch64", "aarch64-musl"}
HOSTS = {"x86_64", "aarch64"}
HEX_SHA = re.compile(r"^[a-f0-9]{40}$")
PACKAGE_FILENAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+~-]*\.xbps$")
PACKAGE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+._-]*$")
RESULT_VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+~-]*$")


def require(ok: bool, message: str) -> None:
    if not ok:
        raise ValueError(message)


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def github_api(repo: str, endpoint: str, token: str, *, method: str = "GET", data=None):
    url = f"https://api.github.com/repos/{repo}/{endpoint}"
    raw_data = json.dumps(data).encode("utf-8") if data is not None else None
    request = Request(
        url,
        method=method,
        data=raw_data,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "OCO-autobump-release",
            "Content-Type": "application/json",
        },
    )
    try:
        with urlopen(request, timeout=50) as response:
            return json.loads(response.read().decode("utf-8"))
    except HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")[:1000]
        raise ValueError(f"GitHub API HTTP {error.code} ({endpoint}): {detail}") from error


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def check_pr(pr: dict, files: list, *, repo: str, plan: dict, allow_merged: bool):
    number = int(plan["pr_number"])
    require(pr["number"] == number, "PR number mismatch")
    require(pr["base"]["ref"] == "OCO", "PR must target OCO")
    require(pr["head"]["repo"]["full_name"] == repo, "PR must come from this repository")
    require(pr["user"]["login"] in {"oSoWoSo-bot", "zen0bit", "zenobit"},
            "Only trusted autobump authors may auto-merge")
    head_ref = pr["head"]["ref"]
    require(head_ref.startswith("autobump/"), "PR head must start with autobump/")
    require(head_ref == plan["head_ref"], "PR source branch has changed")
    require(pr["head"]["sha"] == plan["head_sha"], "PR was updated after tested build")
    require(bool(HEX_SHA.fullmatch(plan["head_sha"])), "Invalid PR head SHA")

    merged = bool(pr["merged"])
    require(pr["state"] == "open" or (allow_merged and merged), "PR is closed without matching merge")
    if not merged:
        require(pr["base"]["sha"] == plan["base_sha"], "OCO advanced since PR build: rebuild required")

    require(pr["changed_files"] == len(files), "PR file list incomplete (pagination) or changed")
    paths = {item["filename"] for item in files}
    template_paths = [path for path in paths if re.fullmatch(r"srcpkgs/[^/]+/template", path)]
    require(len(template_paths) == 1, "Autobump PR must modify exactly one package template")
    package = template_paths[0].split("/")[1]
    require(head_ref.startswith(f"autobump/{package}-"), "Package name differs from autobump branch")
    require(paths <= {"README.md", template_paths[0]}, "Unexpected modified files in autobump PR")
    require(all(item["status"] == "modified" for item in files), "Unexpected added/deleted/renamed files")
    require(plan["packages"].split() == [package], "Build plan does not match changed package")
    require(not plan.get("removed", "").strip(), "Autobump PR unexpectedly removes packages")
    return package


def template_version(repo: str, package: str, head_sha: str, token: str) -> str:
    path = f"srcpkgs/{package}/template"
    response = github_api(repo, f"contents/{path}?ref={head_sha}", token)
    require(response.get("type") == "file" and response.get("path") == path,
            "Could not verify autobump template at tested PR head")
    require(response.get("encoding") == "base64" and isinstance(response.get("content"), str),
            "GitHub returned an unexpected autobump template representation")
    try:
        encoded = "".join(response["content"].split())
        content = base64.b64decode(encoded, validate=True).decode("utf-8")
    except (ValueError, UnicodeDecodeError) as error:
        raise ValueError("Could not decode autobump template at tested PR head") from error

    # Match build-packages.sh: grep '^version=' | head -n1 | cut -d= -f2- |
    # tr -d '"' | tr -d ' '.
    version_line = next((line for line in content.splitlines() if line.startswith("version=")), None)
    require(version_line is not None, "Autobump template has no literal version= assignment")
    version = version_line.split("=", 1)[1].replace('"', "").replace(" ", "")
    require(bool(RESULT_VERSION.fullmatch(version)), "Autobump template has an unsafe version value")
    return version


def check_run(event: dict, plan: dict, repo: str):
    run = event["workflow_run"]
    require(run["event"] == "pull_request", "Source workflow was not a pull_request run")
    require(run["conclusion"] == "success", "Source workflow was not successful")
    require(run["head_branch"] == plan["head_ref"], "Source workflow branch mismatch")
    require(run["head_repository"]["full_name"] == repo, "Source run from another repository")
    require(int(run["id"]) == int(plan["run_id"]), "Artifact from another workflow run")
    require(repo == event["repository"]["full_name"], "Event repository mismatch")
    prs = run.get("pull_requests") or []
    require(any(int(item["number"]) == int(plan["pr_number"]) for item in prs),
            "Source run not associated with this PR")
    for item in prs:
        if int(item["number"]) == int(plan["pr_number"]):
            sha = (item.get("head") or {}).get("sha")
            if sha:
                require(sha == plan["head_sha"], "Run PR head SHA mismatches build manifest")
    require(bool(HEX_SHA.fullmatch(plan["base_sha"])), "Invalid PR base SHA")


def stage(artifacts: Path, staging: Path, plan: dict, target_package: str, expected_version: str):
    require(bool(PACKAGE_NAME.fullmatch(target_package)), "Invalid autobump target package")
    require(bool(RESULT_VERSION.fullmatch(expected_version)), "Invalid expected autobump version")
    matrix = plan["matrix"]
    configs = matrix["config"]
    require(isinstance(configs, list) and bool(configs), "Empty build matrix")
    require(len(configs) <= 16, "Unexpected matrix size")
    expected = set()
    for cfg in configs:
        arch, host = cfg["arch"], cfg["host"]
        require(arch in ARCHES and host in HOSTS, "Unexpected build architecture or host")
        expected.add(f"autobump-bin-{arch}-{host}")
    require(len(expected) == len(configs), "Duplicate matrix arch/host combinations")
    require((artifacts / "autobump-release-plan").is_dir(), "Missing trusted build plan artifact")
    actual = {p.name for p in artifacts.iterdir() if p.is_dir()}
    require(actual == expected | {"autobump-release-plan"},
            f"Unexpected/missing artifacts: expected {sorted(expected)}, found {sorted(actual)}")

    staging.mkdir(parents=True, exist_ok=True)
    paths_by_arch = {}
    results_by_arch = {}
    target_versions = {}
    count = 0
    for artifact_name in sorted(expected):
        folder = artifacts / artifact_name
        require(not folder.is_symlink(), "Artifact directory is a symlink")
        manifest_path = folder / "manifest.json"
        require(manifest_path.is_file() and not manifest_path.is_symlink(), "Missing binary manifest")
        entry = read_json(manifest_path)
        arch, host = entry["arch"], entry["host"]
        require(artifact_name == f"autobump-bin-{arch}-{host}", "Binary manifest architecture mismatch")
        require(isinstance(entry["files"], list) and bool(entry["files"]), "Empty binary artifact")
        binaries = folder / "packages"
        require(binaries.is_dir() and not binaries.is_symlink(), "Missing packages subdirectory")
        expected_files = set()
        for spec in entry["files"]:
            name, digest = spec["name"], spec["sha256"]
            require(bool(PACKAGE_FILENAME.fullmatch(name)), f"Unexpected package filename: {name}")
            require(name.endswith(f".{arch}.xbps"), f"Wrong package arch for {name}")
            require(bool(re.fullmatch(r"[a-f0-9]{64}", digest)), "Invalid package checksum")
            require(name not in expected_files, "Duplicate filename in manifest")
            expected_files.add(name)
            source = binaries / name
            require(source.is_file() and not source.is_symlink(), f"Missing/unsafe XBPS file: {name}")
            require(hash_file(source) == digest, f"SHA256 mismatch: {name}")
            target_dir = staging / arch
            target_dir.mkdir(parents=True, exist_ok=True)
            destination = target_dir / name
            if destination.exists():
                require(paths_by_arch[(arch, name)] == digest,
                        f"Different builds produced conflicting {arch}/{name}")
            else:
                shutil.copyfile(source, destination)
                require(hash_file(destination) == digest, "Staging checksum mismatch")
                paths_by_arch[(arch, name)] = digest
                count += 1
        actual_files = {p.name for p in binaries.iterdir() if p.is_file() and not p.is_symlink()}
        require(actual_files == expected_files, "Extra/unexpected files inside artifact")
        results = folder / "results.tsv"
        require(results.is_file() and not results.is_symlink(), "Missing build result file")
        expected_digest = entry.get("results_sha256", "")
        require(bool(re.fullmatch(r"[a-f0-9]{64}", expected_digest)), "Invalid result checksum")
        require(hash_file(results) == expected_digest, "Result checksum mismatch")
        target_source_rows = 0
        validated_rows = []
        source_ok_rows = set()
        for line in results.read_text(encoding="utf-8").splitlines():
            fields = line.split("\t")
            require(len(fields) in (3, 4) and fields[2] in ("ok", "fail", "skip"),
                    "Malformed build result row")
            require(all("\n" not in field and "\r" not in field for field in fields),
                    "Invalid build result characters")
            package_name, version, status = fields[:3]
            require(bool(PACKAGE_NAME.fullmatch(package_name)), "Invalid package in build result row")
            require(bool(RESULT_VERSION.fullmatch(version)), "Invalid version in build result row")
            if len(fields) == 3:
                validated_rows.append(line)
                if status == "ok":
                    source_ok_rows.add((package_name, version))
            else:
                sourcepkg = fields[3]
                require(bool(PACKAGE_NAME.fullmatch(sourcepkg)),
                        "Invalid source template in binary result row")
                validated_rows.append(line)
                continue
            if package_name != target_package:
                continue
            target_source_rows += 1
            require(target_source_rows == 1,
                    f"Duplicate autobump target source result for {target_package}")
            require(status == "ok", f"Autobump target {target_package} build status is {status}")
            require(version == expected_version,
                    f"Autobump target {target_package} reported {version}, expected {expected_version}")
            target_versions[artifact_name] = version
        for line in validated_rows:
            fields = line.split("\t")
            if len(fields) == 4:
                require((fields[3], fields[1]) in source_ok_rows,
                        f"Binary result {fields[0]} lacks a matching successful source result")
        require(target_source_rows == 1,
                f"Missing autobump target source result for {artifact_name}")
        results_by_arch.setdefault(arch, []).extend(validated_rows)
        require({p.name for p in folder.iterdir()} == {"packages", "manifest.json", "results.tsv"},
                "Unexpected content inside binary artifact")
    require(count > 0, "No new binaries were staged")
    require(set(target_versions) == expected,
            f"Missing autobump target result for matrix builds: {sorted(expected - set(target_versions))}")
    versions = set(target_versions.values())
    require(len(versions) == 1,
            f"Conflicting autobump target versions across matrix builds: {sorted(versions)}")
    for arch, rows in results_by_arch.items():
        target = staging / "results" / f"build-results-{arch}"
        target.mkdir(parents=True, exist_ok=True)
        (target / "results.tsv").write_text("\n".join(sorted(rows)) + "\n", encoding="utf-8")
    return count


def api_token():
    token = os.environ.get("GH_TOKEN", "")
    require(bool(token), "GH_TOKEN missing")
    return token


def prepare(args):
    event = read_json(args.event)
    plan_path = args.artifacts / "autobump-release-plan" / "release.json"
    require(plan_path.is_file(), "Missing release.json in plan artifact")
    plan = read_json(plan_path)
    repo = args.repo
    check_run(event, plan, repo)
    pr_number = int(plan["pr_number"])
    token = api_token()
    pr = github_api(repo, f"pulls/{pr_number}", token)
    files = github_api(repo, f"pulls/{pr_number}/files?per_page=100", token)
    package = check_pr(pr, files, repo=repo, plan=plan, allow_merged=True)
    expected_version = template_version(repo, package, plan["head_sha"], token)
    count = stage(args.artifacts, args.staging, plan, package, expected_version)
    info = dict(plan)
    info["package"] = package
    info["version"] = expected_version
    (args.staging / "release-info.json").write_text(
        json.dumps(info, sort_keys=True, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Validated PR #{pr_number}, head {plan['head_sha']}, {count} XBPS binaries")


def merge(args):
    info = read_json(args.staging / "release-info.json")
    repo = args.repo
    token = api_token()
    number = int(info["pr_number"])
    pr = github_api(repo, f"pulls/{number}", token)
    files = github_api(repo, f"pulls/{number}/files?per_page=100", token)
    check_pr(pr, files, repo=repo, plan=info, allow_merged=True)

    if pr["merged"]:
        sha = pr["merge_commit_sha"]
        require(bool(HEX_SHA.fullmatch(sha or "")), "Merged PR missing commit SHA")
        commit = github_api(repo, f"commits/{sha}", token)
        msg = commit["commit"]["message"]
        require(f"OCO-Autobump-Run: {info['run_id']}" in msg and
                f"OCO-Autobump-Head: {info['head_sha']}" in msg,
                "Merged PR is not associated with this build run")
        print(f"PR #{number} already merged as {sha}; retrying publication")
    else:
        title = f"{pr['title']} (#{number})"
        body = (pr.get("body") or "").strip()
        body += ("\n\n" if body else "") + (
            f"OCO-Autobump-Run: {info['run_id']}\n"
            f"OCO-Autobump-Head: {info['head_sha']}"
        )
        result = github_api(repo, f"pulls/{number}/merge", token, method="PUT", data={
            "sha": info["head_sha"],
            "merge_method": "squash",
            "commit_title": title,
            "commit_message": body,
        })
        require(result.get("merged") is True, "GitHub did not merge the PR")
        sha = result["sha"]
        print(f"Merged PR #{number} as {sha}")

    require(bool(HEX_SHA.fullmatch(sha)), "Invalid resulting merge commit SHA")
    output = os.environ.get("GITHUB_OUTPUT")
    require(bool(output), "GITHUB_OUTPUT missing")
    with open(output, "a", encoding="utf-8") as stream:
        stream.write(f"merge_sha={sha}\n")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("operation", choices=["prepare", "merge"])
    p.add_argument("--event", required=True, type=Path)
    p.add_argument("--artifacts", type=Path)
    p.add_argument("--staging", required=True, type=Path)
    p.add_argument("--repo", required=True)
    args = p.parse_args()
    require(bool(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo)), "Invalid repo")
    if args.operation == "prepare":
        require(args.artifacts is not None, "--artifacts is required for prepare")
        prepare(args)
    else:
        merge(args)


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, TypeError, OSError, json.JSONDecodeError) as error:
        sys.exit(f"error: {error}")
