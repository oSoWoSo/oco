#!/usr/bin/env python3
"""Audit repository-owned file references, including split Python Path joins.

This is a static regression guard, not a shell interpreter: generated paths,
external source trees, URLs and temporary fixtures need integration tests too.
"""
import ast
from html.parser import HTMLParser
from pathlib import Path
import re
import subprocess
import unittest
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
PREFIX = r'(?:\.github/scripts|tools/(?:autobump|build|community|repository|updates|website)|lib|config|website/(?:public|templates))'
REFERENCE = re.compile(r'(?<![A-Za-z0-9_.-])' + PREFIX + r'/[A-Za-z0-9_+.-]+')
MOVED_NAMES = {p.name for directory in ('tools', 'lib', 'config', 'website')
               for p in (ROOT / directory).rglob('*') if p.is_file() and '__pycache__' not in p.parts}
RETIRED = re.compile(r'(?<![A-Za-z0-9_.-])(?:src/(?:' + '|'.join(map(re.escape, sorted(MOVED_NAMES)))
                     + r')|\.github/scripts/ci/[A-Za-z0-9_.-]+|\.github/autobump-batch\.py)')
# Optional inputs and intentionally nonexistent test fixtures, scoped to their
# owners. Do not hide missing paths globally or exclude all tests/comments.
EXCEPTIONS = {
    'ocoman': {'config/feed-blacklist', 'config/feeds-blacklist', 'config/feed_blacklist'},
    'tests/test_repository_layout.py': {
        '.github/scripts/ci', 'website/public/accidental.py', 'website/public/private.conf'},
    'tests/test_autobump_branch.bats': {'.github/scripts/next-step.sh'},
}


def joined_path(node):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
        left, right = joined_path(node.left), joined_path(node.right)
        if left is not None and right is not None:
            return (left.rstrip('/') + '/' + right).lstrip('/')
    if isinstance(node, (ast.Name, ast.Attribute)):
        return ''  # ROOT, self.root, repo_root, etc.
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'Path' and node.args:
        return joined_path(node.args[0])
    return None


def missing_references(name, text):
    missing = set()
    exceptions = EXCEPTIONS.get(name, set())
    if name == 'tests/test_paths.py':
        exceptions = set().union(*EXCEPTIONS.values())  # This file spells out the exceptions.
    for number, line in enumerate(text.splitlines(), 1):
        line = re.sub(r'https?://[^\s\x22\x27<>]+', '', line)
        for match in RETIRED.finditer(line):
            missing.add((number, match.group()))
        for match in REFERENCE.finditer(line):
            path = match.group().rstrip('.')
            # Upstream package recipes/manual describe their own library/configuration
            # trees. /usr/lib in diagnostic fixtures is also external data.
            if ((name.startswith('srcpkgs/') or name == 'Manual.md')
                    and path.startswith(('lib/', 'config/'))):
                continue
            if line[:match.start()].endswith('usr/'):
                continue
            if path not in exceptions and not (ROOT / path).exists():
                missing.add((number, path))
    if name.endswith('.py'):
        for node in ast.walk(ast.parse(text, filename=name)):
            path = joined_path(node)
            if path and RETIRED.fullmatch(path):
                missing.add((node.lineno, path))
            elif path and REFERENCE.fullmatch(path) and path not in exceptions and not (ROOT / path).exists():
                missing.add((node.lineno, path))
    return sorted(missing)


class PathTests(unittest.TestCase):
    def test_all_tracked_repository_file_references_exist(self):
        names = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
        failures = []
        for name in names:
            file = ROOT / name
            if not file.is_file() or file.is_symlink():
                continue
            try:
                text = file.read_text()
            except UnicodeError:
                continue
            failures.extend(f'{name}:{line}: {path}' for line, path in missing_references(name, text))
        self.assertEqual(failures, [], '\n'.join(failures))

    def test_audit_detects_literal_and_constructed_missing_references(self):
        literal = '.github/scripts/' + 'missing-helper.sh'
        constructed = 'ROOT / "tools" / "updates" / "' + 'missing-helper.py"'
        self.assertEqual(missing_references('fixture.sh', 'bash ' + literal), [(1, literal)])
        self.assertIn((1, 'tools/updates/' + 'missing-helper.py'),
                      missing_references('fixture.py', constructed))

    def test_audit_rejects_retired_paths_even_if_local_caches_exist(self):
        path = 'src/' + 'feed.opml'
        self.assertEqual(missing_references('fixture.sh', 'cat ' + path), [(1, path)])
        path = '.github/scripts/' + 'ci/build-gate.sh'
        self.assertIn((1, path), missing_references('fixture.sh', 'bash ' + path))

    def test_website_local_assets_and_generated_links_resolve(self):
        class Links(HTMLParser):
            def __init__(self):
                super().__init__()
                self.paths = []
            def handle_starttag(self, tag, attrs):
                self.paths.extend(value for key, value in attrs if key in {'href', 'src'} and value)
        generated = {'index.html', 'manual.html', 'Manual.md', 'feed.xml',
                     'x86_64', 'x86_64-musl', 'aarch64', 'aarch64-musl'}
        failures = []
        for file in (ROOT / 'website').rglob('*.html'):
            parser = Links()
            parser.feed(file.read_text())
            for link in parser.paths:
                url = urlsplit(link)
                if url.scheme or url.netloc or not url.path or '__' in url.path:
                    continue
                name = url.path.removeprefix('../').rstrip('/')
                if name not in generated and not (ROOT / 'website/public' / name).is_file():
                    failures.append(f'{file.relative_to(ROOT)}: {link}')
        self.assertEqual(failures, [])


if __name__ == '__main__':
    unittest.main()
